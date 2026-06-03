# eks-fleet — agent entry point

You're an AI client (or the author of one) about to vend an EKS cluster, change
the `Cluster` API, or wire the composition to a new substrate module. This file
gets you running in five minutes. For the wider picture — how this repo fits the
nanohype stack — read the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## What this repo gives you

A **Kubernetes-native API for vending EKS clusters**, backed by the existing
Terragrunt substrate:

- **The `Cluster` claim** (`fleet.nanohype.dev/v1alpha1`) — the order. Spec maps
  1:1 to the landing-zone cluster module's inputs (region, version, node sizing,
  the network it needs); status returns the outputs (endpoint, CA, OIDC).
- **The Composition** — the line. Renders provider-terraform `Workspace`
  resources that run the landing-zone `network` → `cluster` chain.
- **ProviderConfigs** — how the hub reaches each spoke: the management cluster's
  Crossplane ServiceAccount assumes a role in the target workload account (IRSA →
  cross-account `AssumeRole`).

The substrate (`landing-zone/components/aws/*`) stays the source of truth — this
repo wraps it, it doesn't reimplement it.

## Contract surface

Every `Cluster` claim:
- Lives in a namespace (the team / tenant boundary), `kind: Cluster`,
  `apiVersion: fleet.nanohype.dev/v1alpha1`.
- Spec fields mirror `landing-zone/components/aws/cluster/variables.tf` exactly
  (`region`, `clusterVersion`, `systemNode*`, plus the account to vend into).
- Status fields mirror that module's `outputs.tf` (`clusterEndpoint`,
  `certificateAuthorityData`, `oidcProviderArn`, `oidcIssuer`, …).
- Is rendered by `compositions/cluster-aws.yaml` against the XRD in
  `apis/cluster/definition.yaml`.

## Vend a cluster

1. Pick the target workload account; ensure its `ProviderConfig` exists
   (`config/providers/`) — the cross-account role the hub assumes.
2. Copy `examples/cluster-dev.yaml`, set `metadata.namespace`,
   `spec.region`, `spec.account`, and the node sizing.
3. `kubectl apply -f` it to the management cluster. ArgoCD does this in the real
   flow; `kubectl` is the manual path.
4. Watch: `kubectl get cluster <name> -o wide` → the status fills in as the
   Workspaces converge (network first, then cluster — EKS takes 20-40 min).

## Conventions

- 2-space YAML. Manifests describe the current state — no migration framing.
- The `Cluster` spec/status field names track the landing-zone module's
  variable/output names (kebab → camelCase). Don't invent a parallel vocabulary.
- provider-terraform runs `tofu`, not `terragrunt` — the `Workspace.module`
  points at a plain-tofu entrypoint, not a Terragrunt component directly. See
  [`docs/architecture.md`](docs/architecture.md).

## Pointers

- [`README.md`](README.md) — overview
- [`apis/cluster/`](apis/cluster/) — the `Cluster` XRD (the API)
- [`compositions/`](compositions/) — the line (XR → Workspaces)
- [`config/`](config/) — management-cluster bootstrap + ProviderConfigs
- [`docs/architecture.md`](docs/architecture.md) — hub/spoke design + open decisions
- [`CLAUDE.md`](CLAUDE.md) — Claude Code session instructions
