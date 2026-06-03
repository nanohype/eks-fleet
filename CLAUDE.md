# CLAUDE.md — eks-fleet

## Overview

The cluster control plane (the hub). Defines a `Cluster` API and Crossplane
Compositions that vend EKS clusters by wrapping the `landing-zone` Terragrunt
substrate via provider-terraform. Runs on a management cluster; manufactures
clusters into workload accounts over cross-account IRSA. Peer to `landing-zone`
(substrate), `eks-gitops` (addon catalog), and `eks-agent-platform` (tenant
control plane / spoke).

## Directory Structure

```
eks-fleet/
├── apis/
│   └── cluster/
│       └── definition.yaml      # CompositeResourceDefinition (the Cluster API)
├── compositions/
│   └── cluster-aws.yaml         # Composition: Cluster XR → provider-terraform Workspaces
├── config/
│   ├── bootstrap/               # Management-cluster install: Crossplane + providers + functions
│   └── providers/               # ProviderConfigs (mgmt IRSA + per-workload-account AssumeRole)
├── examples/                    # Sample Cluster claims
├── docs/                        # Architecture + design decisions
├── crossplane.yaml              # Package metadata (this repo as a Crossplane Configuration)
└── Taskfile.yaml
```

## Key Conventions

### The Cluster API mirrors the substrate
The `Cluster` XRD's spec/status track `landing-zone/components/aws/cluster`'s
`variables.tf` / `outputs.tf` field-for-field (kebab-case vars → camelCase spec).
When the cluster module gains a variable, the XRD gains the matching field — the
composition just patches it onto the `Workspace`. Don't fork the vocabulary.

### Compositions wrap, never reimplement
A Composition renders provider-terraform `Workspace` resources whose `module`
points at the landing-zone substrate. The substrate is the source of truth; this
repo is the ordering API on top. No EKS resources are defined here directly.

### tofu, not terragrunt
provider-terraform runs the `tofu` binary against a module — it does **not** run
`terragrunt`. The landing-zone *components* rely on terragrunt-generated provider
blocks + `_envcommon` dependency wiring, so a `Workspace` can't point at a
component directory as-is. It points at a **plain-tofu entrypoint** (a thin root
module that wires the provider + the network/cluster modules with explicit vars).
That entrypoint is the first build task — see `docs/architecture.md`.

### provider-terraform gotchas (bake into every Workspace)
- Default reconcile timeout (20m) is shorter than an EKS build (20-40m) → set 60m
  on the provider's runtime config.
- State is not persisted in-pod → every Workspace uses the S3 backend.
- Use `https://` git sources, not SSH (no key in the Workspace pod).

## Making Changes

### Add/change a Cluster spec field
1. Edit `apis/cluster/definition.yaml` (the openAPIV3Schema) to add the field.
2. Add a patch in `compositions/cluster-aws.yaml` mapping it onto the Workspace var.
3. `task validate` — yamllint + render the examples.

### Add a workload account (vend into a new spoke)
1. Provision the cross-account role in that account (landing-zone; trusts the hub
   OIDC). 2. Add a `ProviderConfig` in `config/providers/` referencing the role.
3. Set `spec.account` on the claim to that account.

## Validation Commands

```bash
task validate    # yamllint + crossplane render the examples against the compositions
task render      # render a sample Cluster claim → the managed resources
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
