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

- **Management account** `111111111111` (profile `fleet-admin`) — runs the hub.
- **Workload account** `222222222222` (profile `xx`) — receives vended clusters.
- Region `us-west-2`, ARM/Graviton default.
- CLIs: `aws` v2, `kubectl`, `helm`, `tofu` ≥ 1.10.0, `terragrunt`, `crossplane`, `cloudgov`, `jq`.
- Live SSO before each stage: `aws sts get-caller-identity --profile fleet-admin` (and `--profile xx` for cross-account steps). Hand SSO creds in via `! aws sso login --profile <p>`.

## Status before you start

Most of what this runbook originally routed around is now wired; the residue is tracked:

1. **Bootstrap is automatic.** Applying a `Cluster` renders a second Workspace (`fleet/aws/cluster-bootstrap`) that runs Cilium + ArgoCD + the in-cluster ArgoCD Secret once the cluster is Ready, so the spoke self-reconciles the eks-gitops catalog + the operator (spoke-local). Same-account is validated. **Cross-account** also needs `spec.bootstrapAccessRoleArn` set to the hub's Crossplane role (cluster-stack adds an EKS access entry so the hub's ambient `get-token` reaches the spoke API) — confirmed at the first rung-2 vend. The bootstrap Workspace error-loops (with a clear "cluster not Ready yet" message) until cluster-stack populates status, then converges; the explicit render-once-Ready gate rides the planned function-go-templating migration.
2. **Portal can drive vends.** The chart wires the gitops write-paths + watch-back (`gitops.*` + `clusterWatchback.enabled`). Driving from portal is supported; a direct `Cluster` CR also works.
3. **Cluster spec fields wired** — the scalar fields are patched, including `endpointPublicAccess`, so a **private** endpoint is orderable (the stronger control). The two **list** fields (`endpointPublicAccessCidrs`, `systemNodes.instanceTypes`) still fall back to defaults pending the function-go-templating migration — so a *public* cluster's CIDR allowlist isn't yet enforced. Use `endpointPublicAccess: false` for now where you need network restriction.

---

## Stage 1 — Stand up the management hub

Goal: a standing management EKS cluster running Crossplane v2 + provider-opentofu, with the hub IRSA role + S3 state bucket, able to vend.

1. **Provision the management cluster** (hand-authored — the one cluster the fleet doesn't vend). Via the landing-zone env tree for the `management` account: network + cluster + cluster-bootstrap (Cilium + ArgoCD). **Set `enable_eks_interface_endpoint = false`** — the EKS interface endpoint's private DNS shadows the IRSA OIDC issuer and breaks `data.tls_certificate` when the hub later creates vended clusters' OIDC providers.
2. **Provision `fleet-hub`** (`landing-zone/components/aws/fleet-hub`, profile `fleet-admin`) with the management cluster's `oidc_provider_arn` + `oidc_issuer` (issuer **without** the `https://` scheme). Outputs: `hub_role_arn` (`eks-fleet-crossplane`) + the `nanohype-eks-fleet-tfstate` bucket. If the bucket already exists from a prior run, import it or delete it (if it holds only test state) before applying.
3. **Provision `fleet-vend`** in the workload account (`landing-zone/components/aws/fleet-vend`, profile `xx`, `-var hub_role_arn=arn:aws:iam::111111111111:role/eks-fleet-crossplane`). Outputs the `dev-eks-fleet-vend` role (trusts the hub role) + publishes its ARN to SSM `/eks-fleet/dev/fleet-vend/vend_role_arn`.
4. **Point kubectl at the hub:** `aws eks update-kubeconfig --name <mgmt-cluster> --region us-west-2 --profile fleet-admin`.
5. **Install Crossplane v2:** `helm install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace --version 2.3.1`.
6. **Install provider-opentofu + runtime config:** edit `eks-fleet/config/bootstrap/` to set the IRSA ServiceAccount annotation to `hub_role_arn`, then `kubectl apply` it. The runtime config carries `--timeout=60m` (EKS builds run 20–40m) and `--poll=1m`.
7. **Install the function + ProviderConfig:** `kubectl apply -f eks-fleet/config/functions.yaml` and the single `default` `ClusterProviderConfig` (`source: None` → ambient IRSA).
8. **Install the Cluster API:** `kubectl apply -f eks-fleet/apis/cluster/definition.yaml` and `compositions/cluster-aws.yaml`.

**Validate:**
- `kubectl get provider.pkg.crossplane.io provider-opentofu -o wide` → `Healthy=True`.
- `aws iam get-role --role-name eks-fleet-crossplane --profile fleet-admin` and `aws iam get-role --role-name dev-eks-fleet-vend --profile xx` both resolve.
- `aws s3 ls s3://nanohype-eks-fleet-tfstate/ --profile fleet-admin` → versioned bucket.
- `kubectl get xrd clusters.fleet.nanohype.dev` and `kubectl get composition cluster-aws` present.

---

## Stage 2 — Vend a standing cluster

Goal: one real, standing EKS cluster in the workload account, vended through the hub.

The first vend is simplest as a **direct `Cluster` CR** (portal's chart isn't wired for the vend path yet — see gap #2). Driving it from portal is optional and additive.

1. **Apply a `Cluster`** in the `platform` namespace — start from `eks-fleet/examples/`. For cross-account, set `spec.vendRoleArn` to the `dev-eks-fleet-vend` role ARN (from SSM). Required: `account`, `region`, `team`. (Node sizing + public-access CIDRs aren't patched yet — gap #3 — so they take entrypoint defaults.)
2. **Watch it vend:** `kubectl describe cluster <name> -n platform` and the rendered `workspace.opentofu`. Crossplane fetches `landing-zone@main`, runs `tofu apply` in `fleet/aws/cluster-stack/`, and populates `Cluster.status` (`clusterEndpoint`, `certificateAuthorityData`, `oidcProviderArn`, `oidcIssuer`). Expect 20–40m.
3. **(Optional) Drive it from portal instead** once the chart is wired (gap #2): deploy portal on the hub with `CLUSTER_WATCHBACK_ENABLED=true` + `GITOPS_CLUSTERS_REPO_URL` + the git SSH key + the `fleet.nanohype.dev/clusters` RBAC. Order via the Provision UI; the cluster-apply worker commits the CR to `nanohype/clusters`, the hub's `clusters-appset` (in eks-gitops) applies it, and the watch-back auto-registers the cluster as `eks_iam` once its endpoint+CA are up.

**Validate:**
- `kubectl get cluster <name> -n platform -o jsonpath='{.status.clusterEndpoint}'` → non-empty.
- The connection secret `<name>-kubeconfig` exists in the `platform` namespace.
- `cloudgov orphans --profile xx` is clean (no failed-create residue).

---

## Stage 3 — The vended cluster's addons (automatic)

Goal: Cilium + ArgoCD + the addon catalog (incl. the eks-agent-platform operator) reconciled onto the new cluster, so it can run tenants. **This is now automatic** — the `Cluster` composition's second Workspace (`fleet/aws/cluster-bootstrap`, which wraps agent-iam + cluster-bootstrap) runs once cluster-stack populates `Cluster.status`. You don't run `terragrunt apply` by hand; you watch it land.

1. **(Cross-account only)** ensure the `Cluster` set `spec.bootstrapAccessRoleArn` to the hub's Crossplane role — cluster-stack grants it a cluster-admin EKS access entry so the bootstrap's ambient `get-token` can reach the spoke API. Same-account needs nothing.
2. **Watch the bootstrap Workspace converge:** `kubectl get workspace.opentofu <name>-bootstrap -n platform -w`. It errors ("cluster not Ready yet") until cluster-stack publishes the endpoint, then applies: Cilium → CoreDNS roll (fixes the stale-ENI DNS hang) → ArgoCD → the in-cluster ArgoCD `Secret` (with the `environment` + `eks-agent-platform/enabled` labels + the operator IRSA annotations).
3. **Watch the addon waves:** pull the kubeconfig (`kubectl get secret -n platform <name>-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/kubeconfig`), then `KUBECONFIG=/tmp/kubeconfig watch 'kubectl -n argocd get application -o wide'`. Waves deploy in order (networking → security → observability → ai-platform). The operator lands via `addons-agent-operator` (selects the `enabled` label, injects the OIDC annotations as Helm values) — confirm it pulls image **`:0.1.1`+** (the public multi-arch image; `:0.1.0` had an amd64-in-arm64 bug). Set `spec.enableAgentPlatform: false` only to install the operator out of band.

**Validate:**
- `kubectl -n argocd wait --for=condition=SyncedAndHealthy application/app-of-apps --timeout=10m`.
- `kubectl -n eks-agent-platform get deployment` → the operator is Running (not CrashLoop).
- `cloudgov platform audit` → zero findings (operator IRSA correct, boundary attached, no inline policies).

---

## Stage 4 — Tenant go-live

Goal: the four tenant apps live on the cluster — `competitive-intelligence`, `slack-knowledge-bot` (almanac), `digest-pipeline` (dispatch), `incident-response` (marshal). Per tenant, per environment:

1. **Provision per-tenant infra:** `terragrunt apply` the tenant's landing-zone component (Aurora / DynamoDB / SQS / S3 / KMS + the IRSA role). Capture `terragrunt output -json`.
2. **Apply the Platform CR** once per cluster: `kubectl apply -f <tenant>/platform.yaml` — declares the `tenants-protohype` namespace, ResourceQuota, NetworkPolicy, AppProject, and the tenant IRSA. `kubectl wait --for=condition=Ready platform.nanohype.dev/<tenant> -n tenants-protohype --timeout=10m`.
3. **Seed external secrets** in AWS Secrets Manager (External Secrets Operator must be installed — it provides the `aws-secrets-manager` ClusterSecretStore). Per tenant: `competitive-intelligence` → Slack (3 tokens); `almanac` → Slack + WorkOS + Notion + Confluence + Google + a state signing secret (**all** OAuth pairs must exist even if unused, or the ExternalSecret won't sync); `dispatch` → approvers + WorkOS directory + DB credentials; `marshal` → the Grafana OnCall webhook HMAC secret.
4. **Fill chart values** in `<tenant>/chart/values-<env>.yaml`: `aws.platformRoleArn` = the `irsa_role_arn` output, plus the per-tenant `tenantInfra.*` keys (pg/aurora endpoints, DynamoDB tables, SQS URLs — FIFO `.fifo` suffixes must match outputs exactly, KMS key id, buckets). Commit + push.
5. **Register the ApplicationSet** entries in eks-gitops (one per tenant; matrix generator `clusters × list`, valueFiles `values.yaml` + `values-<env>.yaml`, destination `tenants-protohype`). ArgoCD reconciles.

**Validate:**
- `kubectl get applications -n argocd | grep -E 'competitive|almanac|dispatch|marshal'` → all Synced + Healthy.
- Tenant pods Running (watch for IRSA 403s → wrong `platformRoleArn`; Postgres connect failures → wrong `tenantInfra.pgHost`; ExternalSecret sync failures → a missing secret key).
- `marshal`'s public webhook ingress has a cert (cert-manager) and its HMAC matches the Grafana OnCall config.

---

## Teardown

Reverse order. Delete tenant ApplicationSets → delete the `Cluster` CR (the Workspace deletes → `tofu destroy` tears down the cluster) → destroy `fleet-vend` / `fleet-hub` / the state bucket / the management cluster. Then `cloudgov orphans --profile <p>` in each account and reap any residue (EKS log groups, Karpenter SQS/EventBridge) — `tofu destroy` doesn't catch those. Confirm zero EKS/NAT/VPC/EC2/EBS/ELB/EIP before walking away.
