# EKS pod distribution drift demo

Companion repository for the AWS Containers blog post
**"Fix pod distribution drift in Amazon EKS with the Kubernetes descheduler"**.

Reproduces the full experiment: a three-Deployment web fleet (1,000 pods
combined) driven by HPAs under randomized load, each Deployment carrying its
own soft topology spread constraint; a node-availability gap in one AZ
(induced by cordon — `scripts/induce-window.sh` — with an AWS FIS template as
the realistic-interruption variant; see `fis/README-fis.md` for why cordon is
the more controllable instrument against a managed node group); a control
experiment proving running pods do not relocate when capacity returns; and the
descheduler restoring each workload's configured `maxSkew`.

The experiment runs at two scales with the same manifests:

| | Full-scale | Small-scale |
|---|---|---|
| Fleet | 1,000 pods (500/300/200) | 100 pods (50/30/20) |
| Nodes | 21 × m5.2xlarge (7/AZ), node group `ng-drift-1000` | 3 × m5.2xlarge (1/AZ), node group `ng-drift-100` |
| HPAs | `workload/hpa-1000.yaml` | `workload/hpa-100.yaml` |
| Everything else | identical | identical |

> **Cost warning:** the full-scale run's 21 m5.2xlarge nodes are the dominant
> cost. Estimate with the [AWS Pricing Calculator](https://calculator.aws/),
> run in one sitting, and remove the nodegroup promptly. The small-scale run
> reproduces the same behavior at a fraction of the cost.

## Prerequisites

- **An existing Amazon EKS cluster** — Kubernetes 1.36 or later, spanning three
  Availability Zones, created with any tool (console, Terraform, CDK, eksctl).
  This repo does not create clusters; if you need one, follow
  [Creating an Amazon EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-cluster.html).

  The repo's defaults name `us-east-1a/b/c`, but **your cluster's subnets may
  be in different AZs** — check before you start:

  ```bash
  # Set both once; every later step in this README reuses them.
  export CLUSTER=<cluster-name>
  export AWS_REGION=us-east-1        # your cluster's Region

  # Confirm the cluster name resolves (lists the clusters in this Region):
  aws eks list-clusters --region "$AWS_REGION" --output table

  # The && and ${SUBNET_IDS:?} guard matters: on a failed lookup, an empty
  # --subnet-ids makes describe-subnets list EVERY subnet in the account, which
  # looks like a valid answer but is not your cluster's subnets.
  SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.subnetIds' --output text) &&
  aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids ${SUBNET_IDS:?} \
    --query 'sort_by(Subnets,&AvailabilityZone)[].[SubnetId,AvailabilityZone]' \
    --output table
  ```

  Check that **three distinct AZs** appear in the output. If you see fewer (for
  example, two subnets in the same AZ), add a subnet in a third AZ to the
  cluster's VPC before you continue — the topology spread constraints and the
  AZ-unavailability window both assume three zones, so the drift the demo
  reproduces cannot occur with two.

  If they differ, override the AZ names in two places: export `AZ_A`/`AZ_B`/`AZ_C`
  in the shell that runs `scripts/watch-distribution.sh` (otherwise it logs zeros
  for every zone), and edit the `Placement.AvailabilityZone` filter in the FIS
  template. `scripts/induce-window.sh` takes the AZ as an argument, so it needs
  no change.
- `kubectl`, `helm`, and the AWS CLI.
- **`metrics-server` running and serving metrics** — the three HPAs read CPU from
  it, and without it they report `<unknown>/50%` and never scale, which stalls the
  walkthrough before any drift can occur. Install it as an EKS add-on and verify
  before you start:

  ```bash
  kubectl -n kube-system get deploy metrics-server
  kubectl top nodes          # must return numbers, not an error
  ```

- For the FIS path: an IAM role FIS can assume (see `fis/README-fis.md`).

## Repository layout

```
cluster/        node group requirements + AWS CLI commands (tool-agnostic)
monitoring/     kube-prometheus-stack values, Grafana dashboard, recording rules, alerts
workload/       namespace, 3-Deployment web fleet (Services + PDBs), HPAs, load generator
descheduler/    Helm values: CronJob mode for the demo (fast convergence, scoped
                to `demo` ns) and a Deployment-mode variant for live metrics
production/     pilot + production DeschedulerPolicy files and PDB templates
fis/            AWS FIS experiment templates for the AZ unavailability window
scripts/        induce-window.sh (cordon window), watch-distribution.sh
                (30s per-AZ + per-deployment skew CSV), snapshot.sh (phase
                captures), export-prom.sh (chart data as CSV), mark.sh
                (timestamped run timeline)
```

**Demo vs production:** `descheduler/descheduler-values.yaml` is tuned so
convergence is watchable in minutes (2-minute schedule, 200-eviction budget).
For a real rollout, start from `production/policy-pilot.yaml` (one tolerant
namespace, tight budgets), graduate to `production/policy-production.yaml`
after 48–72 clean hours, and put a PDB on every in-scope workload first
(`production/pdb-examples.yaml`). `monitoring/prometheus-alerts.yaml` carries
the alert set — note the CronJob-mode metrics caveat in its header.

## Applying manifests directly from the repository

Set the raw base once; every kubectl/helm step applies straight from this repo:

```bash
# GitHub:
export RAW=https://raw.githubusercontent.com/<ORG>/<REPO>/main
```

For a private
> repo, clone it and apply from the local paths instead.

## Quick start

```bash
# 1. Capacity on your existing cluster — enable prefix delegation FIRST, then
#    create the node group with your tool of choice (AWS CLI commands, subnet
#    and node-role lookups, and verification gates: cluster/README.md)
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
aws eks create-nodegroup --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-100 \
  --scaling-config minSize=21,maxSize=24,desiredSize=21 \
  --instance-types m5.2xlarge --disk-size 30 \
  --subnets <subnet-1a> <subnet-1b> <subnet-1c> \
  --node-role <NODE_ROLE_ARN> --labels role=drift-demo

# 2. Monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 90.0.0 \
  --values "$RAW/monitoring/kube-prometheus-stack-values.yaml"
kubectl apply -f "$RAW/monitoring/pod-distribution-dashboard.yaml"
kubectl apply -f "$RAW/monitoring/recording-rule-per-az.yaml"

# 3. Workload fleet
kubectl apply -f "$RAW/workload/namespace.yaml"
kubectl apply -f "$RAW/workload/web-app.yaml"
kubectl apply -f "$RAW/workload/hpa-1000.yaml"             # or hpa-100.yaml
kubectl apply -f "$RAW/workload/load-generator.yaml"

# 4. Simulate the node-availability gap in the third AZ.
#    drain cordons the nodes AND evicts their pods in one action, honouring
#    PDBs as it goes — closer to real instance loss than deleting pods by hand.
kubectl drain -l topology.kubernetes.io/zone=us-east-1c \
  --ignore-daemonsets --delete-emptydir-data --timeout=10m

# Grafana now shows the third zone empty and skew well above maxSkew:1.
# Return the capacity — the nodes are healthy again:
kubectl uncordon -l topology.kubernetes.io/zone=us-east-1c

# CONTROL EXPERIMENT: wait 5-10 minutes. Nothing moves back. Kubernetes does
# not relocate running pods to satisfy a soft (ScheduleAnyway) constraint.
# This is the drift the descheduler exists to correct.

# 5. Descheduler — install SUSPENDED. The CronJob's 2-minute schedule would
#    otherwise start correcting drift immediately, which destroys the control
#    experiment (proving drift does NOT self-heal) and double-counts any
#    manual pass that a scheduled run overlaps.
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/
helm repo update
helm install descheduler descheduler/descheduler \
  --namespace kube-system \
  --version 0.36.0 \
  --values "$RAW/descheduler/descheduler-values.yaml" \
  --set suspend=true

# Trigger one pass at a time (timestamped: a fixed name collides on re-run)
kubectl -n kube-system create job descheduler-$(date +%H%M%S) --from=cronjob/descheduler
kubectl -n kube-system logs \
  $(kubectl -n kube-system get jobs --sort-by=.metadata.creationTimestamp -o name \
    | grep desched | tail -1) \
  | grep -E "totalEvicted|violate the pod's disruption budget" | tail -5

# PDBs cap evictions per pass, so repeat until the per-workload skew reaches
# maxSkew. Then hand control back to the schedule for the steady-state finish:
kubectl -n kube-system patch cronjob descheduler -p '{"spec":{"suspend":false}}'
```

The full experiment sequence — the unavailability window, the control
experiment, convergence, and what to capture at each phase — is in the blog
post. To induce and close the window:

```bash
./scripts/induce-window.sh open us-east-1c     # use YOUR third AZ name
./scripts/induce-window.sh close us-east-1c
```

## Cleanup

```bash
# 1. Stop the workload first
kubectl delete namespace demo

# 2. Remove the tooling
helm uninstall descheduler -n kube-system
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring        # helm leaves the namespace and PVCs

# 3. Remove the nodes (the dominant cost)
aws eks delete-nodegroup --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-1000
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-1000
```

If the cluster was created solely for this demo, delete it once the node group
is gone (`delete-cluster` fails while a node group is still attached):

```bash
aws eks delete-cluster --name "$CLUSTER" --region "$AWS_REGION"
```

Otherwise your cluster is untouched beyond the removed node group. Three things
outlive the commands above and keep billing:

- **NAT gateway**, if you created one for the node subnets — it survives cluster
  deletion and bills hourly plus data processing.
- **kube-prometheus-stack CRDs**, which `helm uninstall` deliberately leaves in
  place: `kubectl delete crd -l app.kubernetes.io/part-of=kube-prometheus-stack`
- **Prefix delegation** on the VPC CNI, still enabled; disable it if your
  cluster did not use it before.

## Security notes

- Grafana ships with a placeholder admin password in the values file. Change it,
  and reach Grafana via `kubectl port-forward` only — do not expose it with a
  LoadBalancer without authentication in front.
- The FIS template requires an IAM role; see `fis/README-fis.md`.
- Never commit credentials. `captures/`, `run-*/`, and local credential files are
  git-ignored.

### Workload hardening, and what is deliberately not hardened

The demo workloads set, on every pod:

- `allowPrivilegeEscalation: false`
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false` (nothing here talks to the Kubernetes API)
- dropped capabilities — `NET_RAW` on the web pods, `ALL` on the load generator
- readiness and liveness probes — **TCP** on the web pods and **exec** on the
  load generator, deliberately not HTTP: a `GET /` against the `hpa-example`
  image executes its CPU-burning handler, so HTTP probes would add continuous
  load to every pod and distort the very HPA measurements this demo exists to
  take
- the load generator additionally runs as `nobody` (UID 65534) with
  `readOnlyRootFilesystem: true`

**Three findings are accepted rather than fixed.** Static analysis (KICS and
similar) flags the web containers for *Container Running As Root*, *Container
Running With Low UID*, and *Root Container Not Mounted Read-only*. These come
from the upstream
[`registry.k8s.io/hpa-example`](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
image, which runs Apache: it binds port 80 as root and writes its pidfile to the
root filesystem. Setting `runAsNonRoot` or `readOnlyRootFilesystem` prevents the
pod from starting. The image is used because it is the reference workload from
the Kubernetes HPA walkthrough and gives the autoscalers something real to scale
on. This is sample code for a short-lived demo in a dedicated namespace — do not
carry these containers into production; use a non-root image instead.

Informational findings around image digest pinning, `imagePullPolicy: Always`,
LimitRange/ResourceQuota, AppArmor profiles, and pod anti-affinity are likewise
out of scope: they are cluster-level production controls, and digest pinning in
particular would make these manifests considerably harder to read for something
whose purpose is to be read.

## License

MIT-0 (see LICENSE). Sample code; not intended for production use as-is.
