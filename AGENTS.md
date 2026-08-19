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
- **Cross-account reach, when you opt into it** — one cluster-scoped
  `ClusterProviderConfig` (`default`, `credentials: source None` = the provider pod's
  ambient IRSA) serves every account. Set `spec.vendRoleArn` and the Composition puts
  it on the entrypoint's `assume_role`, so the hub's IRSA role assumes the workload's
  `fleet-vend` role (IRSA → cross-account `AssumeRole`). One ClusterProviderConfig,
  not one per account. Leave it unset and the vend runs in the hub's own account.

The substrate (`landing-zone/components/aws/*`) stays the source of truth — this
repo wraps it, it doesn't reimplement it.

## The contract (read this before any example)

Everything below this line is parameterized. The walkthroughs in `docs/` narrate one
particular deployment — one region, one set of profile names — and **that instance is
not the contract**. If you build against the worked example instead of these
defaults, you will put a cluster in the wrong region in someone else's account.

| Knob | Default | Means |
|---|---|---|
| `spec.vendRoleArn` | `""` | **Same-account.** The vend runs with the hub's own credentials. No spoke account, no `fleet-vend` role, nothing to provision. |
| `spec.region` | *required* | Any AWS region. Nothing in this repo pins a region for the workload. |
| `spec.stateBucket` | *required* | The one hub-account bucket holding every vended cluster's tofu state. **No default** — a bucket name is a global-namespace identifier owned by one account, so no value could be right for a second deployment. |
| `spec.stateRegion` | *required* | The **state bucket's** region, deliberately not `spec.region`. Decoupled so a vend into any region still inits against the one hub bucket. Required with `stateBucket`: the two name one thing. |
| `spec.moduleSource` | pinned SHA | The landing-zone commit the Workspace fetches. Pinned, not `?ref=main`, so a vend is reproducible. |

Two conditional rules worth knowing before you generate a spec:

- **`vendRoleArn` set ⇒ both boundary ARNs required.** `clusterPermissionsBoundaryArn`
  and `operatorPermissionsBoundaryArn` must be non-empty, or the `Cluster` is rejected
  at admission. They are *not* required for a same-account vend.
- **`endpointPublicAccess: true` ⇒ non-empty `endpointPublicAccessCidrs`.** An empty
  allowlist would reach the cluster module as `0.0.0.0/0`, so admission rejects it.

Note what is *not* in that table: a default for the state backend. A default would be
one deployment's bucket and region, and omitting the fields would silently point your
`tofu init` at someone else's account — so both are required.
If you are generating a `Cluster`, you must know where its state lives — that is not
a value to inherit from whoever wrote the API.

Both are CEL rules on the XRD, so they fail in milliseconds rather than ~20 minutes
into a `tofu apply`. `apis/cluster/definition.yaml` is the authority; its field
descriptions are written to be read by `kubectl explain cluster`.

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

**The XRD is a published interface with two consumers.** `nanohype/clusters` vendors
a JSON schema derived from `apis/cluster/definition.yaml`, pinned to a specific
eks-fleet commit, and a weekly freshness check opens a PR there when this repo's
`main` moves ahead of the pin. `nanohype/portal` vendors its own copy and asserts
every XRD field is accounted for in its `ClusterSpec` struct — and portal is what
writes `Cluster` CRs in the GitOps flow, so a field portal does not know about is a
field no portal-ordered vend ever sets. If you change the schema — including a
`description` or a `default` — expect it to land as a diff in two other repos. Say so
in your PR body.

## Vend a cluster

### The default path — same account

This is the whole flow when you are not vending across an account boundary. It
needs no `fleet-vend` role, no spoke account, and no boundary ARNs.

1. Copy `examples/cluster-development.yaml`, set `metadata.namespace`,
   `spec.region`, `spec.account`, and the node sizing. Leave `spec.vendRoleArn`
   unset — that is what makes it same-account.
2. `kubectl apply -f` it to the hub cluster (the cluster running Crossplane — often
   called the *management cluster*, which is not the `management` **account**; they
   are different things). ArgoCD does this in the real flow; `kubectl` is the manual
   path.
3. Watch: `kubectl get cluster <name> -n <namespace> -o wide` → the status fills in
   as the Workspace converges (network first, then cluster — EKS takes 20-40 min).
   The kubeconfig connection secret lands in the `Cluster`'s namespace.

### Opting into a cross-account vend

Only when the cluster must land in a *different* account from the hub. Three extra
things, and admission enforces the last two together:

1. The target account needs a `fleet-vend` role (landing-zone
   `components/aws/fleet-vend/`) — the role the hub assumes.
2. Set `spec.vendRoleArn` to it.
3. Set **both** `spec.clusterPermissionsBoundaryArn` and
   `spec.operatorPermissionsBoundaryArn`, or the `Cluster` is rejected at admission.
   Both take the vend boundary that account publishes to SSM at
   `/eks-fleet/<env>/fleet-vend/vend_permissions_boundary_arn`. The fleet role's IAM
   gate only mints roles carrying its exact boundary, so a vend ordered without them
   403s ~20 minutes into the apply; the CEL rule turns that into an instant
   rejection. `examples/cluster-restricted.yaml` is the cross-account shape.

A same-account vend may set the two boundaries to the hub boundary
(`/eks-fleet/<env>/fleet-hub/hub_permissions_boundary_arn`) if you want the same
gating there, but nothing requires it.

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
- [`docs/architecture.md`](docs/architecture.md) — hub/spoke design + the design decisions behind it
- [`CLAUDE.md`](CLAUDE.md) — Claude Code session instructions
