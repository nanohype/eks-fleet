# Runbook: teardown

Tearing down a vend (a spoke) and, when you're done with the fleet, the hub
itself. The substrate-side residue and IAM gaps live in the landing-zone
runbook ([RB-007](https://github.com/nanohype/landing-zone/blob/main/docs/runbooks.md));
this covers the `Cluster`-CR and hub side.

Unless noted, `kubectl` runs against the **hub** cluster.

## Tear down a spoke (the happy path)

1. Delete the tenant ApplicationSets for that spoke (eks-gitops) so ArgoCD stops
   reconciling workloads into a cluster you're about to delete.
2. Delete the `Cluster` CR in its namespace:

   ```bash
   kubectl -n <ns> delete cluster.fleet.nanohype.dev <name>
   ```

   This cascades both Workspaces' `tofu destroy`. The composition's `Usage`
   (of: cluster-stack, by: cluster-bootstrap) enforces the order:
   cluster-bootstrap destroys first — against the still-live spoke API endpoint
   its `tofu destroy` needs — then cluster-stack tears the cluster down.
   `replayDeletion` re-issues the blocked cluster-stack delete the moment the
   bootstrap clears, so you don't wait on the GC backoff.
3. Watch both Workspaces drain:

   ```bash
   kubectl get workspace -A -o wide      # both gone = the spoke is destroyed
   ```

4. Sweep the residue `tofu` never owned — Karpenter EC2/SQS/EventBridge, EKS log
   groups — per landing-zone RB-007: `cloudgov orphans --profile <p>`.

## Reaching the spoke API during teardown (access entries, not the kubeconfig)

If you need `kubectl` against the spoke (to inspect stuck finalizers, drain a
namespace), reach it through an **EKS access entry**, not the connection-secret
kubeconfig. The bootstrap already registered the hub role as cluster-admin via an
access entry (`bootstrap_access_role_arn`), so assume the hub role and
`aws eks update-kubeconfig` against the spoke. To get in as yourself, add your
SSO/admin principal as an access entry on the spoke first — a vended spoke does
**not** trust your SSO role by default. (Don't read the kubeconfig connection
secret; it's a credential.)

## When a Workspace is wedged (external-create-pending)

A Workspace stuck `external-create-pending` blocks both create and delete, and
**you must not cycle the `provider-opentofu` pod mid-apply** — it orphans the
vend (live AWS, empty S3 state). Drop the Workspace finalizer, then delete the
live AWS resources directly in dependency order, and refresh provider creds via
the `aws-creds` secret rather than a pod restart. Full steps in landing-zone
RB-007 ("When It's Truly Wedged").

## Tear down the hub

Once every spoke is gone:

1. Destroy the management-account substrate — `fleet-hub` (the
   `eks-fleet-crossplane` IRSA role + boundary), the tfstate bucket (purge all
   object *versions* first or `DeleteBucket` 409s), then the hub EKS cluster.
2. `cloudgov orphans` in the management account until clean. Confirm zero
   EKS / NAT / VPC / EC2 / EBS / ELB / EIP before walking away.

## Notes carried back from live runs

- **moduleSource is pinned to a SHA, not `main`.** provider-opentofu caches a
  module by its git ref and never re-pulls on retry. Roll the substrate forward
  by bumping the SHA in `apis/cluster/definition.yaml` and
  `compositions/cluster-aws.yaml` in lockstep. To force a re-pull for one
  in-flight `Cluster` (debugging a substrate hotfix), patch its source to a
  different ref:

  ```bash
  kubectl patch cluster.fleet.nanohype.dev <name> --type merge \
    -p '{"spec":{"moduleSource":"git::https://github.com/nanohype/landing-zone.git?ref=<sha>"}}'
  ```

- **Bootstrap sizing.** A fresh spoke's bootstrap nodes must hold the addon
  catalog's pods before Karpenter scales out. eks-gitops enables Cilium ENI
  prefix-delegation (~4× IPs/node) and gives Karpenter a `system-cluster-critical`
  priority so it isn't stranded. A fresh spoke wedging on IPs or DNS is an
  eks-gitops-layer problem, not a vend failure.
