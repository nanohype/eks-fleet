# Production go-live runbook

The end-to-end sequence to stand up a standing fleet hub, vend a real EKS
cluster through it, bootstrap that cluster's addons, and bring the four tenant
apps live on it. This is owner-run — it spends real AWS money and needs live SSO
sessions. Each stage has a validation gate; don't advance until it passes.

The local same-account loop (kind hub → real EKS → teardown) is already proven
(`docs/rung-1-local-validation.md`), and both rungs ran on a real hub once and were
torn down. This runbook is the *standing* version: a hub you keep, a cluster you
keep, tenants on top.

## Accounts & tooling

- **Fleet account** (profile `fleet`) — runs the hub (the standing control plane; a dedicated account, the `live/aws/fleet` tree). Command-level stand-up: [`stand-up-the-hub.md`](stand-up-the-hub.md).
- **Workload account** `222222222222` (profile `xx`) — receives vended clusters.
- Region `us-west-2`, ARM/Graviton default.
- CLIs: `aws` v2, `kubectl`, `helm`, `tofu` ≥ 1.10.0, `terragrunt`, `crossplane`, `cloudgov`, `jq`.
- Live SSO before each stage: `aws sts get-caller-identity --profile fleet` (and `--profile xx` for cross-account steps). Hand SSO creds in via `! aws sso login --profile <p>`.

## Status before you start

What the vend chain handles for you, and what you still set by hand:

1. **Bootstrap is automatic.** Applying a `Cluster` renders a second Workspace (`fleet/aws/cluster-bootstrap`) that runs Cilium + ArgoCD + the in-cluster ArgoCD Secret once the cluster is Ready, so the spoke self-reconciles the eks-gitops catalog + the operator (spoke-local). Same-account is validated. **Cross-account** also needs `spec.bootstrapAccessRoleArn` set to the hub's Crossplane role (cluster-stack adds an EKS access entry so the hub's ambient `get-token` reaches the spoke API) — confirmed at the first rung-2 vend. The bootstrap Workspace is gated on `Cluster.status.clusterEndpoint`: the composition's `function-go-templating` step only renders it once cluster-stack publishes the endpoint, so it never plans against an empty endpoint.
2. **Portal can drive vends.** The chart wires the gitops write-paths + watch-back (`gitops.*` + `clusterWatchback.enabled`). Driving from portal is supported; a direct `Cluster` CR also works.
3. **Cluster spec fields wired** — every field reaches the cluster, scalars and both **list** fields (`endpointPublicAccessCidrs`, `systemNodes.instanceTypes`), which the `function-go-templating` step JSON-encodes into the tofu vars. The API endpoint is private by default; a spec that opts into public access must carry a non-empty CIDR allowlist (a CEL rule on the XRD rejects public-with-empty at admission). See `examples/cluster-restricted.yaml` for the public-opt-in/cross-account shape.

---

## Stage 1 — Stand up the hub

Goal: a standing hub EKS cluster in the dedicated `fleet` account running Crossplane v2 + provider-opentofu + ArgoCD, with the hub IRSA role + the fleet state bucket, able to vend.

**Command-level walkthrough: [`stand-up-the-hub.md`](stand-up-the-hub.md).** It provisions the hub cluster from the landing-zone `live/aws/fleet/us-west-2/hub/` tree (network → cluster → cluster-bootstrap → fleet-hub; the network component carries `enable_eks_interface_endpoint=false`, the OIDC-DNS shadow fix), then installs Crossplane + provider-opentofu (IRSA flavor) + the Cluster API, and smoke-vends one cluster same-account.

For **cross-account** vending into a workload spoke, also provision `fleet-vend` in that account (`landing-zone/components/aws/fleet-vend`, profile `xx`, `-var hub_role_arn=<the eks-fleet-crossplane ARN>`) — it outputs the `dev-eks-fleet-vend` role (trusts the hub role) + publishes its ARN to SSM `/eks-fleet/dev/fleet-vend/vend_role_arn` and its permissions boundary to `/eks-fleet/dev/fleet-vend/vend_permissions_boundary_arn` — and set `spec.vendRoleArn` + the two boundary fields (Stage 2).

**Validate** (gates from stand-up-the-hub.md §2 + §4):
- `aws eks describe-cluster --name hub-eks --region us-west-2 --profile fleet` → `ACTIVE`.
- `kubectl get provider.pkg.crossplane.io provider-opentofu -o wide` → `Healthy=True`.
- `aws s3 ls s3://nanohype-eks-fleet-tfstate/ --profile fleet` → versioned bucket.
- `kubectl get xrd clusters.fleet.nanohype.dev` and `kubectl get composition cluster-aws` present.

---

## Stage 2 — Vend a standing cluster

Goal: one real, standing EKS cluster in the workload account, vended through the hub.

The first vend is simplest as a **direct `Cluster` CR**. Driving it from portal works too (the chart wires the vend path — see status #2) but is optional and additive; the direct CR keeps the first run legible.

1. **Apply a `Cluster`** in the `platform` namespace — start from `eks-fleet/examples/`. For cross-account, set `spec.vendRoleArn` to the `dev-eks-fleet-vend` role ARN (from SSM) and `spec.clusterPermissionsBoundaryArn` + `spec.operatorPermissionsBoundaryArn` to the vend boundary (SSM `/eks-fleet/dev/fleet-vend/vend_permissions_boundary_arn`) — the vend role's IAM gate only mints roles carrying that boundary, and the XRD rejects a `vendRoleArn` without both fields at admission. Same-account, set both to the hub boundary (SSM `/eks-fleet/dev/fleet-hub/hub_permissions_boundary_arn`). Required: `account`, `region`, `team`. Node sizing, instance types, and the public-access CIDR allowlist are all honored (anything omitted takes the entrypoint default); the API endpoint stays private unless the spec opts into public access with an explicit CIDR allowlist.
2. **Watch it vend:** `kubectl describe cluster <name> -n platform` and the rendered `workspace.opentofu`. Crossplane fetches `landing-zone@main`, runs `tofu apply` in `fleet/aws/cluster-stack/`, and populates `Cluster.status` (`clusterEndpoint`, `certificateAuthorityData`, `oidcProviderArn`, `oidcIssuer`). Expect 20–40m.
3. **(Optional) Drive it from portal instead** (the chart wires this — status #2): deploy portal on the hub with `CLUSTER_WATCHBACK_ENABLED=true` + `GITOPS_CLUSTERS_REPO_URL` + the git SSH key + the `fleet.nanohype.dev/clusters` RBAC (and, for cross-account vends, `FLEET_HUB_ROLE_ARN` = the hub's Crossplane role, so portal stamps `spec.bootstrapAccessRoleArn` automatically). Order via the Provision UI; the cluster-apply worker commits the CR to `nanohype/clusters`, the hub's `clusters-appset` (in eks-gitops) applies it, and the watch-back auto-registers the cluster as `eks_iam` once its endpoint+CA are up.

**Validate:**
- `kubectl get cluster <name> -n platform -o jsonpath='{.status.clusterEndpoint}'` → non-empty.
- The connection secret `<name>-kubeconfig` exists in the `platform` namespace.
- `cloudgov orphans --profile xx` is clean (no failed-create residue).

---

## Stage 3 — The vended cluster's addons (automatic)

Goal: Cilium + ArgoCD + the addon catalog (incl. the eks-agent-platform operator) reconciled onto the new cluster, so it can run tenants. **This is now automatic** — the `Cluster` composition's second Workspace (`fleet/aws/cluster-bootstrap`, which wraps agent-iam + cluster-bootstrap) runs once cluster-stack populates `Cluster.status`. You don't run `terragrunt apply` by hand; you watch it land.

1. **(Cross-account only)** ensure `spec.bootstrapAccessRoleArn` is set to the hub's Crossplane role — cluster-stack grants it a cluster-admin EKS access entry so the bootstrap's ambient `get-token` can reach the spoke API. Portal sets this automatically when `FLEET_HUB_ROLE_ARN` is configured; a direct `Cluster` CR sets it by hand. Same-account needs nothing.
2. **Watch the bootstrap Workspace converge:** `kubectl get workspace.opentofu <name>-bootstrap -n platform -w`. It errors ("cluster not Ready yet") until cluster-stack publishes the endpoint, then applies: Cilium → CoreDNS roll (fixes the stale-ENI DNS hang) → ArgoCD → the in-cluster ArgoCD `Secret` (with the `environment` + `eks-agent-platform/enabled` labels + the operator IRSA annotations).
3. **Watch the addon waves:** pull the kubeconfig (`kubectl get secret -n platform <name>-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/kubeconfig`), then `KUBECONFIG=/tmp/kubeconfig watch 'kubectl -n argocd get application -o wide'`. Waves deploy in order (networking → security → observability → ai-platform). The operator lands via `addons-agent-operator` (selects the `enabled` label, injects the OIDC annotations as Helm values) — confirm it pulls image **`:0.1.1`+** (the public multi-arch image; `:0.1.0` had an amd64-in-arm64 bug). Set `spec.enableAgentPlatform: false` only to install the operator out of band.

**Validate:**
- `kubectl -n argocd wait --for=condition=SyncedAndHealthy application/app-of-apps --timeout=10m`.
- `kubectl -n eks-agent-platform get deployment` → the operator is Running (not CrashLoop).
- `cloudgov platform audit` → zero findings (operator IRSA correct, boundary attached, no inline policies).

---

## Stage 4 — Tenant go-live

Goal: the four tenant apps live on the cluster — `competitive-intelligence`, `slack-knowledge-bot`, `digest-pipeline`, `incident-response`. Per tenant, per environment:

1. **Provision per-tenant infra:** `terragrunt apply` the tenant's landing-zone component (Aurora / DynamoDB / SQS / S3 / KMS + the IRSA role). Capture `terragrunt output -json`.
2. **Apply the Platform CR** once per cluster: `kubectl apply -f <tenant>/platform.yaml` (the Platform + BudgetPolicy CRs live in the team namespace `tenants-protohype`) — the operator then provisions the per-tenant workload namespace `tenants-<tenant>`, its ResourceQuota, NetworkPolicy, AppProject (named `<tenant>`), and the tenant IRSA. `kubectl wait --for=condition=Ready platform.nanohype.dev/<tenant> -n tenants-protohype --timeout=10m`.
3. **Seed external secrets** in AWS Secrets Manager (External Secrets Operator must be installed — it provides the `aws-secrets-manager` ClusterSecretStore). Per tenant: `competitive-intelligence` → Slack (3 tokens); `slack-knowledge-bot` → Slack + WorkOS + Notion + Confluence + Google + a state signing secret (**all** OAuth pairs must exist even if unused, or the ExternalSecret won't sync); `digest-pipeline` → approvers + WorkOS directory + DB credentials; `incident-response` → the Grafana OnCall webhook HMAC secret.
4. **Fill chart values** in `<tenant>/chart/values-<env>.yaml`: `aws.platformRoleArn` = the `irsa_role_arn` output, plus the per-tenant `tenantInfra.*` keys (pg/aurora endpoints, DynamoDB tables, SQS URLs — FIFO `.fifo` suffixes must match outputs exactly, KMS key id, buckets). Commit + push.
5. **Register the ApplicationSet** entries in eks-gitops (one per tenant; matrix generator `clusters × list`, valueFiles `values.yaml` + `values-<env>.yaml`, destination `tenants-<tenant>`). ArgoCD reconciles.

**Validate:**
- `kubectl get applications -n argocd | grep -E 'competitive-intelligence|slack-knowledge-bot|digest-pipeline|incident-response'` → all Synced + Healthy.
- Tenant pods Running (watch for IRSA 403s → wrong `platformRoleArn`; Postgres connect failures → wrong `tenantInfra.pgHost`; ExternalSecret sync failures → a missing secret key).
- `incident-response`'s public webhook ingress has a cert (cert-manager) and its HMAC matches the Grafana OnCall config.

---

## Teardown

For the step-by-step playbook — reaching the spoke API through an access entry, clearing an `external-create-pending` wedge, hub teardown, and the moduleSource/sizing notes — see [the teardown runbook](runbooks/teardown.md). The substrate-side residue + IAM lessons are in landing-zone [RB-007](https://github.com/nanohype/landing-zone/blob/main/docs/runbooks.md).

Reverse order. Delete tenant ApplicationSets → delete the `Cluster` CR → destroy `fleet-vend` / `fleet-hub` / the state bucket / the hub cluster. Then `cloudgov orphans --profile <p>` in each account and reap any residue (EKS log groups, Karpenter SQS/EventBridge) — `tofu destroy` doesn't catch those. Confirm zero EKS/NAT/VPC/EC2/EBS/ELB/EIP before walking away.

Deleting the `Cluster` cascades both Workspaces' `tofu destroy`. The composition's `Usage` (of: cluster-stack, by: cluster-bootstrap) enforces the order: cluster-stack's teardown is blocked until cluster-bootstrap is gone, so the bootstrap destroys against a live API endpoint (its `tofu destroy` needs the spoke API) before cluster-stack tears the cluster down. `replayDeletion` re-issues the blocked cluster-stack delete the moment the bootstrap clears, so you don't wait on the GC backoff.
