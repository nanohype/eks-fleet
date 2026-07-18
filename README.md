# eks-fleet

The cluster control plane. `eks-fleet` vends EKS clusters from a declarative
namespaced `Cluster` resource the way [`eks-agent-platform`](https://github.com/nanohype/eks-agent-platform)
vends tenants — one factory line, one layer up.

A Crossplane v2 composition wraps the [`landing-zone`](https://github.com/nanohype/landing-zone)
OpenTofu + Terragrunt substrate, so the IaC stays the source of truth and you get a
Kubernetes-native ordering API on top. It runs on a **management cluster** (the
hub) and manufactures clusters into **workload accounts** (the spokes) via
cross-account IRSA.

**AI clients / agents start here:** [`AGENTS.md`](AGENTS.md). For the stack-wide
view, see the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## The idea

```
Cluster        ──►  Composition  ──►  provider-opentofu Workspace   ──►  EKS in a workload account
 (the order)        (the line)        (wrapping landing-zone modules)     (the product)
```

You apply a namespaced `Cluster` resource. The composition renders a
provider-opentofu `Workspace` that runs the landing-zone `network` → `cluster`
chain (via the `fleet/aws/cluster-stack` entrypoint), and writes the cluster's
endpoint / CA / OIDC back to the `Cluster`'s status. No hand-authored Terragrunt
directory; the line produces it. Under Crossplane v2 the namespaced `Cluster` *is*
the API — a team applies it directly in its own namespace, no claim involved.

## Where it sits

- `landing-zone` — substrate (the parts the composition runs)
- `eks-gitops` — addon catalog + the management cluster's generic runtime (Crossplane, ArgoCD)
- `eks-agent-platform` — tenant control plane (spoke)
- **`eks-fleet`** — **cluster control plane (hub)** ← this repo

## Prerequisites

- A management Kubernetes cluster with Crossplane v2 installed
- `crossplane` CLI (v2), `kubectl`, `yamllint`, `task`

## Commands

```bash
task validate     # yamllint + substrate-contract check + crossplane render (examples + gated-branch fixture)
task contract     # diff the composition's templated var keys against the pinned landing-zone substrate
task render       # render a sample Cluster to the managed resources it produces
task cel-test     # prove the XRD's CEL guardrails reject bad specs (spins a throwaway kind cluster)
```

## License

[Apache-2.0](LICENSE).
