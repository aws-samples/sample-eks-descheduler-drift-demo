# EKS pod distribution drift demo

Companion repository for the AWS Containers blog post
**"Fix pod distribution drift in Amazon EKS with the Kubernetes descheduler"** (CONTAINERS-238).

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
  be in different AZs** (1b/1d/1f is common) — check before you start:

  ```bash
  aws ec2 describe-subnets \
    --subnet-ids $(aws eks describe-cluster --name "$CLUSTER" \
      --query 'cluster.resourcesVpcConfig.subnetIds' --output text) \
    --query 'Subnets[].[SubnetId,AvailabilityZone]' --output table
  ```

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
# GitLab:
export RAW=https://gitlab.com/<GROUP>/<REPO>/-/raw/main
```

> The repository must be **public** (or the URLs otherwise reachable without
> authentication) for direct `kubectl apply -f "$RAW/..."` to work — kubectl
> does not send credentials when fetching manifests over HTTPS. For a private
> repo, clone it and apply from the local paths instead.

## Quick start

```bash
# 1. Capacity on your existing cluster — enable prefix delegation FIRST, then
#    create the node group with your tool of choice (AWS CLI commands, subnet
#    and node-role lookups, and verification gates: cluster/README.md)
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
aws eks create-nodegroup --cluster-name <cluster> --nodegroup-name ng-drift-1000 \
  --scaling-config minSize=21,maxSize=24,desiredSize=21 \
  --instance-types m5.2xlarge --disk-size 30 \
  --subnets <subnet-1a> <subnet-1b> <subnet-1c> \
  --node-role <NODE_ROLE_ARN> --labels role=drift-demo

# 2. Monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values "$RAW/monitoring/kube-prometheus-stack-values.yaml"
kubectl apply -f "$RAW/monitoring/pod-distribution-dashboard.yaml"
kubectl apply -f "$RAW/monitoring/recording-rule-per-az.yaml"

# 3. Workload fleet
kubectl apply -f "$RAW/workload/namespace.yaml"
kubectl apply -f "$RAW/workload/web-app.yaml"
kubectl apply -f "$RAW/workload/hpa-1000.yaml"             # or hpa-100.yaml
kubectl apply -f "$RAW/workload/load-generator.yaml"

# 4. Descheduler — suspend the CronJob before any manual run, or a scheduled
#    run can fire seconds later and double-count the correction
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/
helm repo update
helm install descheduler descheduler/descheduler \
  --namespace kube-system \
  --values "$RAW/descheduler/descheduler-values.yaml"
kubectl -n kube-system patch cronjob descheduler -p '{"spec":{"suspend":true}}'
kubectl -n kube-system create job descheduler-now --from=cronjob/descheduler
kubectl -n kube-system logs -f job/descheduler-now
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
kubectl delete namespace demo
helm uninstall descheduler -n kube-system
helm uninstall monitoring -n monitoring
aws eks delete-nodegroup --cluster-name <cluster> --nodegroup-name ng-drift-1000
```

Your cluster is untouched beyond the removed node group (prefix delegation on
the VPC CNI remains enabled; disable it if your cluster did not use it before).

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
