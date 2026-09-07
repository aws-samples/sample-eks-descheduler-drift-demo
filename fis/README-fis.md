# AWS FIS: node unavailability window

`az-unavailability-template.json` stops every demo node group instance in one
AZ for 20 minutes (`startInstancesAfterDuration: PT20M`), then restarts them.
Stopping the EC2 instances backing an EKS node group removes those nodes from
scheduling — the same API-level outcome as a cordon, a Spot interruption, or a
managed node group upgrade, but delivered as a controlled experiment.

Targeting uses the `eks:nodegroup-name` tag, which EKS applies to managed node
group instances **automatically** regardless of how the node group was created.
(Custom tags on a node group do not propagate to its instances, so don't target
those.) The template ships targeting `ng-drift-1000`; change the tag value to
`ng-drift-100` for the small-scale run.

## Setup

1. Create an IAM role FIS can assume, trusted by `fis.amazonaws.com`, with the
   `AWSFaultInjectionSimulatorEC2Access` managed policy (or a scoped-down
   equivalent limited to instances tagged `project=pod-distribution-drift-demo`).
2. Fill in `roleArn` in the template.
3. Create and run:

```bash
aws fis create-experiment-template \
  --cli-input-json file://fis/az-unavailability-template.json
aws fis start-experiment --experiment-template-id <template-id>
```

## Notes

- **The window will NOT last `startInstancesAfterDuration` on a managed node
  group.** The node group's Auto Scaling group sees the stopped instance as
  unhealthy and launches a *replacement* in the same AZ — measured at roughly
  3 minutes in the 100-pod run, against a PT20M setting. The AZ therefore has
  schedulable capacity back almost immediately, under a new node name. That is
  fine if you are testing interruption handling; it is wrong if you need a zone
  to stay unschedulable for a distribution experiment.

  For the distribution experiment, prefer `scripts/induce-window.sh` (cordon),
  which holds for exactly as long as you leave it cordoned. Use FIS when the
  point is a realistic instance-loss event rather than a controlled window.

  (Counter-intuitively, the early healing made the control experiment *stronger*
  in Run A: capacity returned within minutes and the pods still did not move for
  the next 2h45m.)

- FIS is the demo's primary method for realistic instance loss.
  `scripts/induce-window.sh` (kubectl cordon) is the zero-IAM fallback and the
  more controllable option; both converge on nodes the scheduler will not
  place on.
- **Important difference from cordon:** stopped instances take their pods down
  with them (pods already in the target AZ are killed, not stranded). Expect
  the "before" distribution to be closer to N/N/0 than N/N/small. Note which
  method you used when capturing.
- On Spot node groups, consider `aws:ec2:send-spot-instance-interruptions`
  instead — it delivers a real interruption notice and exercises the
  interruption handler.
- FIS also ships a built-in scenario, "AZ Availability: Power Interruption",
  which does this plus subnet/ELB disruption. It is broader than this demo needs.
