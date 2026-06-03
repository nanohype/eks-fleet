# eks-fleet

The cluster control plane. `eks-fleet` vends EKS clusters from a declarative
`Cluster` claim the way [`eks-agent-platform`](https://github.com/nanohype/eks-agent-platform)
vends tenants — one factory line, one layer up.

A Crossplane composition wraps the [`landing-zone`](https://github.com/nanohype/landing-zone)
Terragrunt substrate, so the IaC stays the source of truth and you get a
Kubernetes-native ordering API on top. It runs on a **management cluster** (the
hub) and manufactures clusters into **workload accounts** (the spokes) via
cross-account IRSA.

**AI clients / agents start here:** [`AGENTS.md`](AGENTS.md). For the stack-wide
view, see the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## The idea

```
Cluster claim  ──►  Composition  ──►  provider-terraform Workspaces  ──►  EKS in a workload account
 (the order)        (the line)        (wrapping landing-zone modules)      (the product)
```

You submit a `Cluster` CR. The composition renders provider-terraform `Workspace`
resources that run the landing-zone `network` → `cluster` chain, and writes the
cluster's endpoint / CA / OIDC back to the claim's status. No hand-authored
Terragrunt directory; the line produces it.

## Where it sits

- `landing-zone` — substrate (the parts the composition runs)
- `eks-gitops` — addon catalog + the management cluster's generic runtime (Crossplane, ArgoCD)
- `eks-agent-platform` — tenant control plane (spoke)
- **`eks-fleet`** — **cluster control plane (hub)** ← this repo

## Status

Scaffold. The repo shape, the `Cluster` API surface, and the composition pattern
are established; the build (the plain-tofu entrypoint the wrap needs, the
management-cluster bootstrap, cross-account vending) is in flight. See
[`docs/architecture.md`](docs/architecture.md) for the design + the open decisions.

## Prerequisites

- A management Kubernetes cluster with Crossplane v1.18+ (or v2) installed
- `crossplane` CLI, `kubectl`, `yamllint`, `task`

## Commands

```bash
task validate     # yamllint + crossplane render the examples against the compositions
task render       # render a sample Cluster claim to the managed resources it produces
```

## License

[Apache-2.0](LICENSE).
