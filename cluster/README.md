# Adding demo capacity to your cluster

Works with **any** EKS cluster — created via console, Terraform, CDK, eksctl,
or anything else. The demo needs a managed node group that satisfies these
requirements; the tool you use to create it is up to you:

| Requirement | Why |
| --- | --- |
| `m5.2xlarge`, 3 nodes (100-pod run) or 21 nodes (1,000-pod run), spread across `us-east-1a/b/c` | Symmetric per-AZ capacity is what makes the drift a placement artifact, not a capacity artifact |
| VPC CNI prefix delegation enabled **before** the node group is created | Managed node groups then auto-calculate max pods (110 for m5.2xlarge) — no launch template needed |
| A standard [EKS node IAM role](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html) | Reuse the role from an existing node group if you have one |

> **FIS targeting note:** EKS automatically tags every managed node group
> instance with `eks:nodegroup-name`. The FIS experiment template targets that
> tag — custom tags set on a node group do *not* propagate to instances, so
> don't rely on those.

## Using the AWS CLI

**1. Gather your cluster's plumbing** (subnets, one per AZ, and a node role):

```bash
CLUSTER=<your-cluster-name>

# Subnets in the cluster's VPC config, with their AZs — pick one per AZ:
aws ec2 describe-subnets \
  --subnet-ids $(aws eks describe-cluster --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.subnetIds' --output text) \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output table

# Node role — reuse the one from an existing node group:
aws eks list-nodegroups --cluster-name "$CLUSTER"
aws eks describe-nodegroup --cluster-name "$CLUSTER" \
  --nodegroup-name <existing-ng> --query 'nodegroup.nodeRole' --output text
# (No existing node group? Create the role per the EKS node IAM role docs above.)
```

**2. Enable prefix delegation FIRST** (this is what makes the auto-calculated
max pods land at 110 instead of 58 — it only affects nodes created afterward):

```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
```

**3. Create the node group** (full-scale shown; for the 100-pod run use
`--nodegroup-name ng-drift-100` and `minSize=3,maxSize=4,desiredSize=3`):

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name ng-drift-1000 \
  --scaling-config minSize=21,maxSize=24,desiredSize=21 \
  --instance-types m5.2xlarge \
  --disk-size 30 \
  --subnets <subnet-1a> <subnet-1b> <subnet-1c> \
  --node-role <NODE_ROLE_ARN> \
  --labels role=drift-demo

aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name ng-drift-1000
```

**4. Verify before proceeding** — both gates must pass:

```bash
# Even AZ spread (1/1/1 or 7/7/7):
kubectl get nodes -l eks.amazonaws.com/nodegroup=ng-drift-1000 \
  -L topology.kubernetes.io/zone

# Max pods = 110 on the new nodes (proves prefix delegation was on in time):
kubectl get nodes -l eks.amazonaws.com/nodegroup=ng-drift-1000 \
  -o custom-columns='NAME:.metadata.name,MAXPODS:.status.allocatable.pods'
```

If max pods shows 58, the node group was created before prefix delegation took
effect — delete and recreate it.

## Cleanup

```bash
aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name ng-drift-1000
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name ng-drift-1000
```

Your cluster is otherwise untouched. Prefix delegation on the VPC CNI remains
enabled; unset it if your cluster didn't use it before.

## Other tools

Console: [Create a managed node group](https://docs.aws.amazon.com/eks/latest/userguide/create-managed-node-group.html).
Terraform/CDK/eksctl: match the requirements table — same instance type, node
counts, subnets across the three AZs, and prefix delegation enabled first.
