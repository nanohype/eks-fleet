# CLAUDE.md — eks-fleet

## Overview

The cluster control plane (the hub). Defines a `Cluster` API and Crossplane v2
Compositions that vend EKS clusters by wrapping the `landing-zone` OpenTofu +
Terragrunt substrate via provider-opentofu. Runs on a management cluster;
manufactures clusters into workload accounts over cross-account IRSA. Peer to
`landing-zone` (substrate), `eks-gitops` (addon catalog), and `eks-agent-platform`
(tenant control plane / spoke).

## Directory Structure

```
eks-fleet/
├── apis/
│   └── cluster/
│       └── definition.yaml      # CompositeResourceDefinition (the namespaced Cluster API)
├── compositions/
│   └── cluster-aws.yaml         # Composition: Cluster → provider-opentofu Workspace
├── config/
│   ├── bootstrap/               # Management-cluster install: Crossplane + provider + functions
│   ├── local/                   # Local kind hub: provider + ClusterProviderConfig (source None, creds via mounted Secret file)
│   ├── functions.yaml           # function-go-templating + function-auto-ready
│   ├── providers/               # The hub ClusterProviderConfig (single, source None)
│   └── reaper.yaml              # Orphan-Workspace reaper CronJob
├── examples/                    # Sample Cluster resources
├── docs/                        # Architecture + design decisions
├── scripts/                     # reap-orphans.sh (backs the reaper CronJob)
├── crossplane.yaml              # Package metadata (this repo as a Crossplane Configuration)
└── Taskfile.yaml
```

## Key Conventions

### The Cluster API is namespaced (Crossplane v2)
The XRD is `apiextensions.crossplane.io/v2`, `scope: Namespaced`, `kind: Cluster`
(plural `clusters`). Under v2 the namespaced `Cluster` *is* the API — a team applies
it directly in its own namespace. There's no claim and no separate composite; don't
reintroduce one. The Composition stays `apiextensions.crossplane.io/v1`, `mode:
Pipeline` — a `function-go-templating` step renders the Workspaces (so list-typed
vars JSON-encode and the bootstrap Workspace gates on the cluster being Ready),
then `function-auto-ready` marks the XR ready once both Workspaces converge.

### The Cluster API mirrors the substrate
The `Cluster` XRD's spec/status track the `fleet/aws/cluster-stack` entrypoint
inputs (which wrap `landing-zone/components/aws/cluster`'s `variables.tf` /
`outputs.tf`) field-for-field (kebab-case vars → camelCase spec). When the cluster
module gains a variable, the XRD gains the matching field — the composition just
templates it onto the `Workspace` var. Don't fork the vocabulary.

### Compositions wrap, never reimplement
A Composition renders a provider-opentofu `Workspace`
(`opentofu.m.upbound.io/v1beta1`) whose `module` points at the landing-zone
substrate. The substrate is the source of truth; this repo is the ordering API on
top. No EKS resources are defined here directly.

### tofu, not terragrunt
provider-opentofu runs the `tofu` binary against a module — it does **not** run
`terragrunt`. The landing-zone *components* rely on terragrunt-generated provider
blocks + `_envcommon` dependency wiring, so a `Workspace` can't point at a
component directory as-is. It points at a **plain-tofu entrypoint**
(`landing-zone/fleet/aws/cluster-stack/` — a thin root module that wires the
provider + the network/cluster modules with explicit vars). See
`docs/architecture.md`.

### Credentials: ClusterProviderConfig, source None
A single cluster-scoped `ClusterProviderConfig` named `default` serves every
account. Production uses `credentials: [{filename: aws-creds.ini, source: None}]` —
no creds file is written, so the provider pod's ambient IRSA (the
`provider-opentofu` ServiceAccount's `eks.amazonaws.com/role-arn`) supplies the AWS
SDK credential chain. The local kind hub uses the same `source: None`; there the
credential chain resolves through the `aws-creds` Secret mounted onto the provider
pod as a shared credentials file (`AWS_SHARED_CREDENTIALS_FILE`,
`config/local/providers.yaml`). The Workspace references it via
`providerConfigRef: {kind: ClusterProviderConfig, name: default}`.

### provider-opentofu gotchas (bake into the runtime config)
- Default reconcile timeout (20m) is shorter than an EKS build (20-40m) → set
  `--timeout=60m`.
- provider-opentofu defaults to a 10m drift/output poll → set `--poll=1m` so the
  `Cluster` status stays fresh as the Workspace converges.
- State is not persisted in-pod → every Workspace uses the S3 backend. The
  per-cluster state key rides on the Workspace `initArgs`
  (`-backend-config=key=fleet/<name>/terraform.tfstate` + region), which complete
  the entrypoint's partial `backend "s3" {}` block.
- Use `https://` git sources, not SSH (no key in the Workspace pod).
- The kubeconfig connection secret lands in the `Cluster`'s namespace (namespaced
  MRs write connection secrets locally under v2).

## Making Changes

### Add/change a Cluster spec field
1. Edit `apis/cluster/definition.yaml` (the openAPIV3Schema) to add the field.
2. Template it onto the Workspace var in `compositions/cluster-aws.yaml` (a
   `{key, value}` entry; list-typed fields go through `toJson | quote`).
3. `task validate` — yamllint + render the examples.

### Add a workload account (vend into a new spoke)
1. Provision the `fleet-vend` role in that account (landing-zone
   `components/aws/fleet-vend/`; trusts the hub's `eks-fleet-crossplane` role).
2. Set `spec.vendRoleArn` on the `Cluster` to that account's `fleet-vend` role ARN —
   the Composition templates it straight onto the entrypoint's `assume_role` (var
   `assume_role_arn`). `spec.account` records the target account (tags/provenance);
   it is not load-bearing for the assume-role. No new ClusterProviderConfig: the
   single `default` (source None) serves every account; cross-account targeting rides
   on `spec.vendRoleArn`, not on a per-account ProviderConfig.
3. Set `spec.clusterPermissionsBoundaryArn` + `spec.operatorPermissionsBoundaryArn`
   to that account's vend boundary (SSM
   `/eks-fleet/<env>/fleet-vend/vend_permissions_boundary_arn`) — fleet-vend's IAM
   gate only allows role writes carrying its exact boundary, so every role the vend
   mints (cluster, nodes, Karpenter, the agent-platform operator) must ship with it.
   The XRD rejects a `vendRoleArn` without both at admission; a wrong value can't
   weaken anything (the gate 403s), it just fails the vend. Same-account hub vends
   use the hub boundary (SSM `/eks-fleet/<env>/fleet-hub/hub_permissions_boundary_arn`)
   instead; only the ungated local kind hub leaves them empty.

## Validation Commands

```bash
task validate    # yamllint + crossplane render the examples against the compositions
task render      # render a sample Cluster → the managed resources
```

## CI

- PR + push to `main` → `.github/workflows/ci.yml`: yamllint, then `crossplane render`
  each example against the compositions (catches schema/template drift without a cluster).

## Claude Code Tooling

### Guarded Operations
- **Allowed**: `task`, `yamllint`, `crossplane render`/`validate`, `kustomize`, file rendering.
- **Denied**: `kubectl apply`, `crossplane` install/apply against a live cluster,
  `terragrunt`/`tofu apply` — this is a config repo; cluster mutation happens via
  ArgoCD on the management cluster, not from here.
