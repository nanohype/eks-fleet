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
│   ├── local/                   # Local kind hub: provider + Secret-cred ClusterProviderConfig
│   ├── functions.yaml           # function-patch-and-transform
│   └── providers/               # The hub ClusterProviderConfig (single, source None)
├── examples/                    # Sample Cluster resources
├── docs/                        # Architecture + design decisions
├── crossplane.yaml              # Package metadata (this repo as a Crossplane Configuration)
└── Taskfile.yaml
```

## Key Conventions

### The Cluster API is namespaced (Crossplane v2)
The XRD is `apiextensions.crossplane.io/v2`, `scope: Namespaced`, `kind: Cluster`
(plural `clusters`). Under v2 the namespaced `Cluster` *is* the API — a team applies
it directly in its own namespace. There's no claim and no separate composite; don't
reintroduce one. The Composition stays `apiextensions.crossplane.io/v1`, `mode:
Pipeline`, `function-patch-and-transform`.

### The Cluster API mirrors the substrate
The `Cluster` XRD's spec/status track the `fleet/aws/cluster-stack` entrypoint
inputs (which wrap `landing-zone/components/aws/cluster`'s `variables.tf` /
`outputs.tf`) field-for-field (kebab-case vars → camelCase spec). When the cluster
module gains a variable, the XRD gains the matching field — the composition just
patches it onto the `Workspace`. Don't fork the vocabulary.

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
SDK credential chain. The local kind hub uses `source: Secret` (the `aws-creds`
Secret) instead. The Workspace references it via
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
2. Add a patch in `compositions/cluster-aws.yaml` mapping it onto the Workspace var.
3. `task validate` — yamllint + render the examples.

### Add a workload account (vend into a new spoke)
1. Provision the `fleet-vend` role in that account (landing-zone
   `components/aws/fleet-vend/`; trusts the hub's `eks-fleet-crossplane` role).
2. Set `spec.account` on the `Cluster` to that account — the Composition derives the
   vend-role ARN (`spec.vendRoleArn`) and the entrypoint's `assume_role` uses it. No
   new ClusterProviderConfig: the single `default` (source None) serves every
   account; cross-account targeting rides on the `Cluster`, not on a per-account
   ProviderConfig.

## Validation Commands

```bash
task validate    # yamllint + crossplane render the examples against the compositions
task render      # render a sample Cluster → the managed resources
```

## CI

- PR + push to `main` → `.github/workflows/ci.yml`: yamllint, then `crossplane render`
  each example against the compositions (catches schema/patch drift without a cluster).

## Claude Code Tooling

### Guarded Operations
- **Allowed**: `task`, `yamllint`, `crossplane render`/`validate`, `kustomize`, file rendering.
- **Denied**: `kubectl apply`, `crossplane` install/apply against a live cluster,
  `terragrunt`/`tofu apply` — this is a config repo; cluster mutation happens via
  ArgoCD on the management cluster, not from here.
