# Security Policy

## Disclaimer

This project is sample/educational code accompanying an AWS Containers blog post.
It is NOT intended for production use without additional security hardening.

## Reporting Vulnerabilities

Report potential security issues to AWS Security via
https://aws.amazon.com/security/vulnerability-reporting/ — do not open a public GitHub issue.

## AWS Services Used

- Amazon EKS (pre-existing cluster the manifests target)
- AWS Fault Injection Service (optional AZ-unavailability experiment)
- Amazon EC2 (managed node group capacity)

## Known Security Considerations

| Item | Category | Rationale |
|------|----------|-----------|
| hpa-example web image runs as root, not read-only | Accepted (demo) | Upstream Apache image binds :80 as root and writes its pidfile to the root FS; runAsNonRoot/readOnlyRootFilesystem break startup. Short-lived demo in the `demo` namespace only. |
| Container image not tagged/digest-pinned | Security Debt | Kept untagged for readability; pin tag + digest for reproducible/production use. |
| Helm charts installed without --version | Security Debt | Pin chart versions for reproducible installs. |
| Grafana placeholder admin password | Accepted (demo) | Change before install; reach Grafana via kubectl port-forward only. |

## Production Hardening Recommendations

- Replace hpa-example with a non-root web image; set runAsNonRoot + readOnlyRootFilesystem.
- Pin container images to a tag + digest (image@sha256:...).
- Pin Helm chart versions with --version.
- Source the Grafana admin password from a Kubernetes Secret (existingSecret).
- Add LimitRange/ResourceQuota to the demo namespace for production workloads.
- Scope the FIS execution role to the minimum required actions.

## Resource Cleanup

1. kubectl delete namespace demo
2. helm uninstall descheduler -n kube-system
3. helm uninstall monitoring -n monitoring
4. aws eks delete-nodegroup --cluster-name <cluster> --nodegroup-name ng-drift-1000
5. Disable VPC CNI prefix delegation if your cluster did not use it before.

## Dependencies

No application dependency manifests are shipped. Community Helm charts
(kube-prometheus-stack, descheduler) are installed at runtime — pin their versions.
