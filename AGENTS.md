# eks-fleet — agent entry point

You're an AI client (or the author of one) about to vend an EKS cluster, change
the `Cluster` API, or wire the composition to a new substrate module. This file
gets you running in five minutes. For the wider picture — how this repo fits the
nanohype stack — read the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## What this repo gives you

A **Kubernetes-native API for vending EKS clusters**, backed by the existing
landing-zone OpenTofu substrate:

- **The namespaced `Cluster`** (`fleet.nanohype.dev/v1alpha1`) — the order. Under
  Crossplane v2 a team applies this resource directly in its own namespace; it *is*
  the API (no claim, no separate composite). Spec maps 1:1 to the landing-zone
  cluster module's inputs (region, version, node sizing, the network it needs);
  status returns the outputs (endpoint, CA, OIDC).
- **The Composition** — the line. Renders a provider-opentofu `Workspace`
  (`opentofu.m.upbound.io/v1beta1`) that runs the landing-zone `network` → `cluster`
  chain via the `fleet/aws/cluster-stack` entrypoint.
- **Cross-account reach** — one cluster-scoped `ClusterProviderConfig` (`default`,
  `credentials: source None` = the provider pod's ambient IRSA) serves every
  account. For a spoke, the Composition sets the entrypoint's `assume_role` from the
  `Cluster`'s `vendRoleArn`, so the hub's IRSA role assumes the workload's
  `fleet-vend` role (IRSA → cross-account `AssumeRole`). One ClusterProviderConfig,
  not one per account.

The substrate (`landing-zone/components/aws/*`) stays the source of truth — this
repo wraps it, it doesn't reimplement it.

## Contract surface

Every `Cluster`:
- Lives in a namespace (the team / tenant boundary), `kind: Cluster`,
  `apiVersion: fleet.nanohype.dev/v1alpha1`.
- Spec fields mirror the `fleet/aws/cluster-stack` entrypoint inputs (which wrap
  `landing-zone/components/aws/cluster/variables.tf`) — `region`, `clusterVersion`,
  `systemNodes.*`, plus the account to vend into.
- Status fields mirror that module's `outputs.tf` (`clusterEndpoint`,
  `certificateAuthorityData`, `oidcProviderArn`, `oidcIssuer`, …).
- Is rendered by `compositions/cluster-aws.yaml` against the XRD in
  `apis/cluster/definition.yaml`.

## Vend a cluster

1. Pick the target workload account; ensure its `fleet-vend` role exists
   (landing-zone `components/aws/fleet-vend/`) — the cross-account role the hub
   assumes. A same-account vend needs nothing here.
2. Copy `examples/cluster-development.yaml`, set `metadata.namespace`,
   `spec.region`, `spec.account`, and the node sizing.
3. **Cross-account only — set the boundary ARNs.** `spec.vendRoleArn` is rejected
   at admission unless `spec.clusterPermissionsBoundaryArn` **and**
   `spec.operatorPermissionsBoundaryArn` are both non-empty (a CEL rule on the
   XRD). Both take the vend boundary the target account publishes to SSM at
   `/eks-fleet/<env>/fleet-vend/vend_permissions_boundary_arn`. The fleet role's
   IAM gate only mints roles carrying its exact boundary, so a vend ordered
   without them 403s ~20 minutes into the apply — the CEL rule turns that into an
   instant rejection. A same-account hub vend leaves `vendRoleArn` empty and the
   rule never fires; set both to the hub boundary
   (`/eks-fleet/<env>/fleet-hub/hub_permissions_boundary_arn`) if you want the
   same gating there. `examples/cluster-restricted.yaml` is the cross-account shape.
4. `kubectl apply -f` it to the hub cluster (the management cluster that runs
   Crossplane — not the `management` *account*, which is a different thing).
   ArgoCD does this in the real flow; `kubectl` is the manual path.
5. Watch: `kubectl get cluster <name> -n <namespace> -o wide` → the status fills in
   as the Workspace converges (network first, then cluster — EKS takes 20-40 min).
   The kubeconfig connection secret lands in the `Cluster`'s namespace.

## Conventions

- 2-space YAML. Manifests describe the current state — no migration framing.
- The `Cluster` spec/status field names track the landing-zone module's
  variable/output names (kebab → camelCase). Don't invent a parallel vocabulary.
- provider-opentofu runs `tofu`, not `terragrunt` — the `Workspace.module` points
  at a plain-tofu entrypoint, not a Terragrunt component directly. See
  [`docs/architecture.md`](docs/architecture.md).

## Pointers

- [`README.md`](README.md) — overview
- [`apis/cluster/`](apis/cluster/) — the `Cluster` XRD (the API)
- [`compositions/`](compositions/) — the line (`Cluster` → Workspace)
- [`config/`](config/) — management-cluster bootstrap + the hub ClusterProviderConfig
- [`docs/architecture.md`](docs/architecture.md) — hub/spoke design + open decisions
- [`CLAUDE.md`](CLAUDE.md) — Claude Code session instructions
