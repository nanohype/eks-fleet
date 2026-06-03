# eks-fleet architecture

## The thesis

`eks-agent-platform`'s operator vends **tenants** from a `Platform` CR. `eks-fleet`
vends **clusters** from a `Cluster` claim — the same factory pattern, one layer
up. You don't hand-author a Terragrunt directory per cluster; you place an order
and the line produces it.

The substrate doesn't change. `landing-zone` stays the source of truth for *what
a cluster is*; `eks-fleet` is the Kubernetes-native ordering API that runs it.

## Hub and spoke

```
              management account (the hub)
   ┌─────────────────────────────────────────────┐
   │  management EKS cluster                       │
   │   Crossplane + provider-terraform + ArgoCD    │
   │                                               │
   │   Cluster claim ──► Composition ──► Workspace │
   │                                        │      │
   └────────────────────────────────────────┼──────┘
                                             │ assume-role (IRSA chain)
                ┌────────────────────────────┼────────────────────────────┐
                ▼                             ▼                            ▼
        workload-dev account          workload-staging            workload-prod
        EKS (the product)             EKS                          EKS
        + per-cluster eks-agent-platform operator (its own tenant control plane)
```

- **Hub** — one management EKS in the `management` account. The one cluster you
  hand-author (it's what vends the rest). Runs Crossplane + provider-terraform +
  ArgoCD; holds the `Cluster` API, the compositions, the ProviderConfigs.
- **Spokes** — workload clusters, manufactured into workload accounts. Each gets
  its own `eks-agent-platform` operator (the tenant control plane) once it's up.

## Wrapping the substrate (the key design choice)

provider-terraform runs the **`tofu` binary** against a module — it does **not**
run `terragrunt`. The `landing-zone` *components* depend on terragrunt-generated
provider blocks and `_envcommon` dependency wiring, so a `Workspace` cannot point
at `components/aws/cluster` directly.

So the composition's `Workspace` points at a **plain-tofu entrypoint** — a thin
root module that wires `network → cluster` (and later `cluster-bootstrap`,
`agent-iam`) with explicit providers + vars, the same chaining the env tree does,
made tofu-native. **Building that entrypoint is the first build task.** Two ways:
1. A `landing-zone/fleet/cluster-stack/` tofu root that `module`-calls the existing
   component modules (keeps everything in landing-zone). ← default
2. A terragrunt-aware runner image for the Workspace (heavier, less standard).

The `Cluster` XRD's `spec.moduleSource` points at that entrypoint.

## The Cluster API maps to the substrate

`apis/cluster/definition.yaml` tracks `landing-zone/components/aws/{network,cluster}`
field-for-field:

| Cluster spec | cluster module var | Cluster status | cluster module output |
|---|---|---|---|
| `region` | `region` | `clusterEndpoint` | `cluster_endpoint` |
| `clusterVersion` | `cluster_version` | `certificateAuthorityData` | `cluster_certificate_authority_data` |
| `systemNodes.*` | `system_node_*` | `oidcProviderArn` | `oidc_provider_arn` |
| `network.vpcCidr` | (network) `vpc_cidr` | `oidcIssuer` | `oidc_issuer` |
| `account` | → ProviderConfig | `karpenterIamRoleArn` | `karpenter_iam_role_arn` |

When the cluster module gains a variable, the XRD gains the field and the
composition adds one patch. No parallel vocabulary.

## provider-terraform gotchas (designed-around)

- **Timeout** — the 20m default is shorter than an EKS build (20-40m); the
  `DeploymentRuntimeConfig` sets 60m. Without it, the apply is killed mid-flight
  and leaks a half-built cluster + a stuck state lock.
- **State** — not persisted in-pod; every Workspace uses the shared S3 backend.
- **Git source** — `https://`, not SSH (no key in the Workspace pod).
- **Cross-resource wiring** — if the entrypoint is split into multiple Workspaces
  later, network→cluster outputs flow through the XR status (extra reconcile
  loops). The single-entrypoint approach above avoids it.

## Cross-account vending

The hub's Crossplane SA is IRSA-bound to a management-account role. That role
`sts:AssumeRole`s a `terraform-vend` role in each workload account (provisioned by
landing-zone, scoped trust + permissions boundary — the same shape as the
operator's per-tenant IRSA). One `ProviderConfig` per account, named
`aws-<account>`, picked by `spec.account`. The 2nd AWS account enters here, and
not before.

## Where it plugs into the stack

- **Order desk** — `portal` grows a `Cluster` form (it already registers clusters
  + stores creds). `fab` does intake/validation.
- **Delivery** — ArgoCD on the management cluster applies the `Cluster` claims
  (GitOps), and bootstraps each new spoke (eks-gitops addons + the operator).
- **QC** — extend `cloudgov` to audit clusters (not just tenants); Kyverno on the
  claims.
- **Runtime** — the management cluster's generic Crossplane/ArgoCD install rides
  in `eks-gitops` (it's just another cluster). This repo holds only the product
  definitions — mirroring the operator (eks-agent-platform) vs installs-it
  (eks-gitops) split.

## Build roadmap

1. **The entrypoint** — the plain-tofu root that wraps `network → cluster`.
2. **Rung 0** — stand up the management cluster; install Crossplane + the provider.
3. **Rung 1 — vend one cluster, same account.** A `Cluster` claim → an EKS cluster
   in the management account (no cross-account yet). The cluster analog of the
   operator's first reconcile. Validate teardown (delete the claim → cluster gone).
4. **Rung 2 — cross-account.** Add the `terraform-vend` role + a per-account
   `ProviderConfig`; vend into workload-dev.
5. **Day-2** — once the claim API is proven, migrate the hot path to **Cluster API
   / CAPA** for upgrade/lifecycle maturity (the XRD stays the front door).

## Open decisions

- Entrypoint shape (single root vs per-component Workspaces).
- Crossplane v1 claim (`XCluster`/`Cluster`) vs v2 namespaced XR — currently the
  claim form for compatibility; v2 is the direction.
- Whether the per-cluster `eks-agent-platform` operator install is part of this
  composition (a follow-on Workspace / ArgoCD app) or a separate bootstrap step.
- provider-terraform (TF 1.5.7, BSL) vs **provider-opentofu** for the runner.
