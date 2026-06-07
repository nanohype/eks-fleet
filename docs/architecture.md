# eks-fleet architecture

## The thesis

`eks-agent-platform`'s operator vends **tenants** from a `Platform` CR. `eks-fleet`
vends **clusters** from a `Cluster` resource — the same factory pattern, one layer
up. You don't hand-author a Terragrunt directory per cluster; you place an order
and the line produces it.

The substrate doesn't change. `landing-zone` stays the source of truth for *what
a cluster is*; `eks-fleet` is the Kubernetes-native ordering API that runs it.

## Hub and spoke

```
              management account (the hub)
   ┌─────────────────────────────────────────────┐
   │  management EKS cluster                       │
   │   Crossplane v2 + provider-opentofu + ArgoCD  │
   │                                               │
   │   Cluster ──► Composition ──► Workspace       │
   │                                  │            │
   └──────────────────────────────────┼───────────┘
                                       │ assume-role (IRSA chain)
                ┌──────────────────────┼──────────────────────────────────┐
                ▼                       ▼                                  ▼
        workload-dev account          workload-staging            workload-prod
        EKS (the product)             EKS                          EKS
        + per-cluster eks-agent-platform operator (its own tenant control plane)
```

- **Hub** — one management EKS in the `management` account. The one cluster you
  hand-author (it's what vends the rest). Runs Crossplane v2 + provider-opentofu +
  ArgoCD; holds the `Cluster` API, the compositions, the hub ClusterProviderConfig.
  Apply the hub's `cluster-stack` with **`enable_eks_interface_endpoint = false`** —
  the EKS interface endpoint's private DNS shadows the IRSA OIDC issuer
  (`oidc.eks.<region>.amazonaws.com` → NXDOMAIN), which the in-VPC provider-opentofu
  runner must resolve to create each vended cluster's OIDC provider
  (`data.tls_certificate`). With it off, the hub reaches the EKS API publicly via NAT.
  This is hub-only: vended clusters keep the endpoint (they're never provisioned from
  inside their own VPC), so the `Cluster` XRD intentionally **omits** this knob — the
  hub is hand-authored via `cluster-stack`, not ordered through the `Cluster` API, so it
  doesn't fall under the "every cluster-stack var gets an XRD field" contract.
- **Spokes** — workload clusters, manufactured into workload accounts. Each gets
  its own `eks-agent-platform` operator (the tenant control plane) once it's up.

Under Crossplane v2 the `Cluster` is a **namespaced** resource — a team applies it
directly in its own namespace, and that resource *is* the API. There's no claim and
no separate composite; the namespaced `Cluster` is both the order desk and the unit
the composition reconciles.

## Wrapping the substrate (the key design choice)

provider-opentofu runs the **`tofu` binary** against a module — it does **not**
run `terragrunt`. The `landing-zone` *components* depend on terragrunt-generated
provider blocks and `_envcommon` dependency wiring, so a `Workspace` cannot point
at `components/aws/cluster` directly.

So the composition's `Workspace` points at a **plain-tofu entrypoint** — a thin
root module that wires `network → cluster` (and later `cluster-bootstrap`,
`agent-iam`) with explicit providers + vars, the same chaining the env tree does,
made tofu-native. That entrypoint is `landing-zone/fleet/aws/cluster-stack/`: a tofu
root that `module`-calls the existing component modules, so everything stays in
landing-zone. It owns the AWS provider (region + default_tags + an optional
cross-account `assume_role`) and a partial `backend "s3" {}` block.

The `Cluster` spec's `moduleSource` points at that entrypoint.

## The Cluster API maps to the substrate

`apis/cluster/definition.yaml` tracks the `fleet/aws/cluster-stack` entrypoint
inputs (which wrap `landing-zone/components/aws/{network,cluster}`) field-for-field:

| Cluster spec | cluster module var | Cluster status | cluster module output |
|---|---|---|---|
| `region` | `region` | `clusterEndpoint` | `cluster_endpoint` |
| `clusterVersion` | `cluster_version` | `certificateAuthorityData` | `cluster_certificate_authority_data` |
| `systemNodes.*` | `system_node_*` | `oidcProviderArn` | `oidc_provider_arn` |
| `network.vpcCidr` | (network) `vpc_cidr` | `oidcIssuer` | `oidc_issuer` |
| `vendRoleArn` | `assume_role_arn` | `karpenterIamRoleArn` | `karpenter_iam_role_arn` |

When the cluster module gains a variable, the XRD gains the field and the
composition templates one more var. No parallel vocabulary.

## provider-opentofu gotchas (designed-around)

- **Timeout** — the 20m default is shorter than an EKS build (20-40m); the
  `DeploymentRuntimeConfig` sets `--timeout=60m`. Without it, the apply is killed
  mid-flight and leaks a half-built cluster + a stuck state lock.
- **Poll interval** — provider-opentofu defaults to a 10m drift/output poll, which
  leaves the `Cluster` status stale for minutes after an apply completes. The
  runtime config sets `--poll=1m` so the status reflects the Workspace promptly.
- **State** — not persisted in-pod; every Workspace uses the shared S3 backend.
  The per-cluster state key rides on the Workspace `initArgs`
  (`-backend-config=key=fleet/<name>/terraform.tfstate`, `-backend-config=region=<region>`,
  plus a static bucket + `encrypt`), which complete the entrypoint's partial
  `backend "s3" {}` block — so every `Cluster` gets an isolated state object.
- **Git source** — `https://`, not SSH (no key in the Workspace pod).
- **Cross-resource wiring** — if the entrypoint is split into multiple Workspaces
  later, network→cluster outputs flow through the composite status (extra reconcile
  loops). The single-entrypoint approach above avoids it.

## Credentials and cross-account vending

A single cluster-scoped `ClusterProviderConfig` named `default` serves every
account. It carries `credentials: [{filename: aws-creds.ini, source: None}]` —
`source: None` writes no credentials file, so the provider pod's ambient IRSA (the
`provider-opentofu` ServiceAccount's `eks.amazonaws.com/role-arn`) supplies the AWS
SDK credential chain. Every Workspace references it via
`providerConfigRef: {kind: ClusterProviderConfig, name: default}`.

The hub's `provider-opentofu` ServiceAccount is IRSA-bound to a management-account
role (`eks-fleet-crossplane`, trusting
`system:serviceaccount:crossplane-system:provider-opentofu`). That role
`sts:AssumeRole`s a `fleet-vend` role (resource `${env}-eks-fleet-vend`, IAM path
`/eks-fleet/`) in each workload account — provisioned by landing-zone's
`components/aws/fleet-vend/`, scoped trust + permissions boundary, the same shape as
the operator's per-tenant IRSA. Targeting is picked by `spec.account` (the
Composition derives the vend-role ARN, or honors an explicit `spec.vendRoleArn`),
which feeds the entrypoint's `assume_role` var — not a per-account ProviderConfig.
The 2nd AWS account enters here, and not before.

The Workspace's kubeconfig connection secret lands in the `Cluster`'s own namespace:
under Crossplane v2, namespaced managed resources write connection secrets locally
alongside the resource.

## Where it plugs into the stack

- **Order desk** — `portal` grows a `Cluster` form (it already registers clusters
  + stores creds). `fab` does intake/validation.
- **Delivery** — ArgoCD on the management cluster applies the namespaced `Cluster`
  resources (GitOps), and bootstraps each new spoke (eks-gitops addons + the operator).
- **QC** — extend `cloudgov` to audit clusters (not just tenants); Kyverno on the
  `Cluster` resources.
- **Runtime** — the management cluster's generic Crossplane/ArgoCD install rides
  in `eks-gitops` (it's just another cluster). This repo holds only the product
  definitions — mirroring the operator (eks-agent-platform) vs installs-it
  (eks-gitops) split.

## Build roadmap

1. **The entrypoint** — the plain-tofu root that wraps `network → cluster`.
2. **Rung 0** — stand up the management cluster; install Crossplane v2 + provider-opentofu.
3. **Rung 1 — vend one cluster, same account.** A namespaced `Cluster` → an EKS
   cluster in the management account (no cross-account yet). The cluster analog of
   the operator's first reconcile. Validate teardown (delete the `Cluster` →
   cluster gone).
4. **Rung 2 — cross-account.** Add the `fleet-vend` role (landing-zone
   `components/aws/fleet-vend/`); vend into workload-dev via `spec.account`.
5. **Day-2** — once the API is proven, migrate the hot path to **Cluster API /
   CAPA** for upgrade/lifecycle maturity (the `Cluster` resource stays the front door).

## Teardown and orphan reaping

Deleting a `Cluster` runs `tofu destroy` through the Workspace, which removes
everything in state. Two classes of resource can escape that and must be swept
separately — they're tied to a cluster but not always in tofu state:

- **EKS control-plane log groups** (`/aws/eks/<cluster>/cluster`). A clean `tofu
  destroy` removes the tofu-owned log group, but a teardown that *wasn't* a clean
  destroy (a hand-killed run) leaves it — and a same-named re-vend then fails with
  `ResourceAlreadyExistsException`.
- **Karpenter interruption infra** (the `Karpenter-<cluster>` SQS queue + the
  `Karpenter*` EventBridge rules). If an apply created the AWS resource but errored
  before tofu recorded it — e.g. `PutRule` succeeded but `TagResource` was denied —
  the resource exists, isn't in state, and (for a rule) isn't tagged. The next apply
  makes a fresh one; the first is orphaned.

`scripts/reap-orphans.sh` (`task reap-orphans PROFILE=<p> [REGION=…] [APPLY=1]`)
sweeps both by delegating to **cloudgov**, the org governance CLI that owns orphan
detection and remediation: `cloudgov orphans` flags dead-cluster residue and
`cloudgov remediate --type orphans` synthesizes the delete script. Each candidate is
tied to a cluster name (in its name or a `ClusterName` tag) and is only reaped when
that cluster is **not** in `eks:ListClusters`; a Karpenter rule missing the
`ClusterName` tag is treated as failed-create debris (a healthy rule from the module
always carries it). Live clusters' resources never match. The wrapper scopes the scan
to the cluster-residue kinds, is **DRY-RUN by default** (prints the delete script for
review), and needs `cloudgov` + `jq` on PATH. Run it after a teardown, or periodically
per workload account.

## Decided

### Entrypoint shape — single root

One Crossplane `Workspace` per `Cluster` runs the whole
`landing-zone/fleet/aws/cluster-stack` tofu root, which wires `network → cluster`
natively (`module.cluster` consumes `module.network`'s `vpc_id` + subnet ids). We
do not split the components into their own chained Workspaces. tofu's DAG already
owns that ordering, so per-component Workspaces would re-encode the same graph in
composition YAML, round-trip outputs through composite status, and fragment both
the apply's atomicity and the per-cluster S3 state — for no upside. The "compositions
wrap, never reimplement" line holds: one root, one state key, one `assume_role`, one
reconcile.

The scope of the rejection is precise — no splitting *within a provider boundary*.
The cluster-stack stays AWS-only; the cluster-bootstrap step (below) pulls k8s/helm
providers and therefore lands in a separate sibling root by provider-boundary
necessity. That's the only multi-Workspace shape this decision allows.

**How the vars are rendered:** a `function-go-templating` step templates every spec
field onto the Workspace as a `{key, value}` var — the scalars (`region`, `environment`,
`team`, `cluster_name`, `cluster_version`, `vpc_cidr`, `vendRoleArn → assume_role_arn`,
`endpointPublicAccess`, `network.maxAzs`, `network.natGateways`, and
`systemNodes.{minSize,maxSize,desiredSize,diskSize}`) as quoted strings (tofu coerces
bool/number from the string value), and the two **list-typed** fields —
`endpointPublicAccessCidrs` and `systemNodes.instanceTypes` — as JSON via `toJson | quote`.
provider-opentofu passes vars as `-var=key=value` flags, and tofu parses a `-var` value
of `["a","b"]` as a real `list(string)`, so the JSON encoding round-trips — which is how
the security-relevant `endpointPublicAccessCidrs` allowlist reaches the cluster (the
cluster module treats an empty list as `["0.0.0.0/0"]`, so an empty allowlist =
unrestricted; a set one restricts the public API). `endpointPublicAccess: false` remains
the stronger control — a fully private API endpoint. Spec lookups use `dig` so an explicit
`false` / `0` / empty list is honored, not collapsed to the default. Vars are keyed by name
(not a position-coupled `vars[]` index), so adding a field is a one-line template edit.

### Operator install — a separate bootstrap Workspace

cluster-stack builds the EKS cluster and emits its identity (`clusterEndpoint`,
`certificateAuthorityData`, `oidcProviderArn`, `oidcIssuer`) to `Cluster.status`. It is
AWS-only — no helm/kubernetes provider, no operator, no addon. Cluster addons (including
the `eks-agent-platform` operator) land via ArgoCD reconciling the `eks-gitops` catalog
onto a registered spoke, not from the cluster definition. This keeps the eks-fleet
(product definitions) vs eks-gitops (installs-it) boundary intact, keeps standing
cluster-admin out of the hub's vend identity, and keeps blast radius per-cluster — a bad
operator can't ride the Composition to every cluster at once.

The bridge from "cluster exists" to "cluster reconciles the catalog" is the
**cluster-bootstrap Workspace** — a second provider-opentofu root the composition renders
once the cluster publishes its endpoint to `Cluster.status` (its k8s/helm/kubectl providers
are why it's a sibling root, not folded into AWS-only cluster-stack). It runs the
landing-zone `fleet/aws/cluster-bootstrap` entrypoint (agent-iam + the cluster-bootstrap
component): installs Cilium + ArgoCD and writes the in-cluster ArgoCD `Secret` carrying the
operator's IRSA wiring as annotations plus an `eks-agent-platform/enabled` label. The
`eks-gitops` `addons-agent-operator` ApplicationSet selects on that label and injects the
annotations as Helm values, so the operator deploys IRSA-bound with no account id in a
public repo. `spec.enableAgentPlatform` toggles whether that label is written (false
installs the operator out of band, e.g. the e2e harness); either way the cluster is still
bootstrapped (Cilium + ArgoCD + the catalog).

On teardown the order has to reverse: cluster-bootstrap's `tofu destroy` needs the spoke
API that cluster-stack provides, so the composition renders a `Usage`
(`protection.crossplane.io`, of: cluster-stack, by: cluster-bootstrap) that blocks
cluster-stack's deletion until the bootstrap Workspace is gone. `replayDeletion` re-issues
the held cluster-stack delete the moment the bootstrap clears, so the cascade doesn't wait
on the garbage-collector backoff. (Both Workspaces carry explicit names so the Usage can
reference them; the Usage is marked ready in-template so it doesn't gate the XR.)

**Topology — spoke-local ArgoCD (decided).** Each vended cluster runs its own ArgoCD,
reconciling the shared eks-gitops catalog onto itself — the bootstrap Secret is the
`in-cluster` entry (`https://kubernetes.default.svc`), pointing ArgoCD at the spoke it
runs on. We do not run a hub ArgoCD that reaches into every spoke: at fleet scale that
concentrates cluster-admin to all spokes in one place (blast radius) and bottlenecks
reconciliation on a single instance. Spoke-local scales linearly and keeps each
reconciler scoped to its own cluster. Consequently the spoke **self-registers** —
cluster-bootstrap writing the in-cluster Secret is the whole registration; nothing needs
to `argocd cluster add` a spoke to a central ArgoCD. (Portal's own cluster inventory is a
separate concern — it records the vended cluster for connection-test + tenant vending,
not for ArgoCD.) A single-pane-of-glass view, if wanted later, is a hub-level rollup over
the spokes' ArgoCDs, not a centralized reconciler.
