# Stand up the EKS hub (rung 0)

The command-level walkthrough for standing up the standing **eks-fleet management
hub** — a real EKS cluster in a dedicated `fleet` account running Crossplane v2 +
provider-opentofu + ArgoCD, able to vend clusters into workload accounts. This is
the detailed version of `production-go-live.md` Stage 1; the orchestration spine
(vend → addons → tenants) continues there.

You drive this — it spends real AWS money (~$45–70/day for a standing hub). Each
step has a validation gate; don't advance until it passes.

## Where the hub lives

A dedicated **`fleet`** account — separate from the org-payer account AND from the
workload (spoke) accounts, so the cluster factory sits outside the workload blast
radius. Accounts are independent (no AWS Org required); cross-account vending works
on plain IAM trust (`fleet-hub` → `fleet-vend`). Its landing-zone env tree is
`live/aws/fleet/us-west-2/hub/`.

## Prereqs

- A `fleet` AWS account + an SSO admin profile for it. Brand-new account → do
  landing-zone `docs/first-deploy-aws.md` § "Account & Identity Setup" first (IAM
  Identity Center, admin user, MFA, `aws configure sso`), then come back here.
- CLIs: `aws` v2, `tofu` ≥ 1.10.0, `terragrunt`, `kubectl`, `helm`, the Crossplane
  v2 `crossplane` CLI, `task`, `jq`.
- Region `us-west-2`, ARM/Graviton default.
- A live SSO session: `aws sso login --profile fleet`. Export `AWS_PROFILE=fleet`
  so terragrunt picks it up.

> **Two repos, one session.** Steps 1–2 run from the **landing-zone** repo root,
> step 4 from the **eks-fleet** repo root; step 3 and the smoke vend (step 5) are
> `kubectl`, run from anywhere. Keep the same `AWS_PROFILE=fleet` shell throughout.

## 1. Point the fleet account id + state backend

```bash
export AWS_PROFILE=fleet
# The real fleet account id — injected at apply time so it never lands in a
# tracked file (account.hcl stays a placeholder).
export TERRAGRUNT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# State bucket {account_id}-{region}-tfstate (idempotent), from the landing-zone root.
cd <landing-zone repo root>
./scripts/init-backend-aws.sh "$TERRAGRUNT_ACCOUNT_ID" us-west-2
```

## 2. Provision the hub cluster

From the landing-zone repo root. Order matters (terragrunt deps enforce it):

```bash
task apply CLOUD=aws ACCOUNT=fleet REGION=us-west-2 ENVIRONMENT=hub COMPONENT=network            # ~3-5 min
task apply CLOUD=aws ACCOUNT=fleet REGION=us-west-2 ENVIRONMENT=hub COMPONENT=cluster            # ~15-25 min
task apply CLOUD=aws ACCOUNT=fleet REGION=us-west-2 ENVIRONMENT=hub COMPONENT=cluster-bootstrap  # ~5-10 min
task apply CLOUD=aws ACCOUNT=fleet REGION=us-west-2 ENVIRONMENT=hub COMPONENT=fleet-hub          # ~1 min
```

- `network` carries `enable_eks_interface_endpoint=false` — the hub provisions
  vended clusters' OIDC providers from inside this VPC, and the interface
  endpoint's private DNS would shadow the IRSA OIDC issuer subdomain.
- `cluster` is public-endpoint so you can reach the API; `cluster-bootstrap` lands
  Cilium + ArgoCD.
- `fleet-hub` mints the `eks-fleet-crossplane` IRSA role + the
  `nanohype-eks-fleet-tfstate` bucket (the vended clusters' state backend).

> If fleet-hub fails with `BucketAlreadyOwnedByYou` on `nanohype-eks-fleet-tfstate`
> (the bucket exists from a prior run but isn't in state yet), adopt it and re-apply:
> `cd live/aws/fleet/us-west-2/hub/fleet-hub && terragrunt import aws_s3_bucket.fleet_state nanohype-eks-fleet-tfstate`,
> then re-run the fleet-hub apply. (Or `aws s3 rb s3://nanohype-eks-fleet-tfstate --force`
> if it's empty and you'd rather start clean.)

**Validate:**
- `aws eks describe-cluster --name hub-eks --region us-west-2` → `ACTIVE`.
- `cd live/aws/fleet/us-west-2/hub/fleet-hub && terragrunt output -raw hub_role_arn`
  → the `eks-fleet-crossplane` role ARN (keep it for step 4).
- `aws s3 ls s3://nanohype-eks-fleet-tfstate/` → the versioned bucket.

## 3. kubectl at the hub

```bash
aws eks update-kubeconfig --name hub-eks --region us-west-2
kubectl get nodes
kubectl -n argocd get pods    # cluster-bootstrap's ArgoCD
```

## 4. Install the control plane (Crossplane + provider + the Cluster API)

The hub uses the **IRSA flavor** (`config/bootstrap/` + `config/providers/`), not
the kind `config/local/`. From the **eks-fleet** repo root:

```bash
# Crossplane v2
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace --version 2.3.1
kubectl -n crossplane-system rollout status deploy/crossplane --timeout=180s

# provider-opentofu — inject the hub role ARN onto the SA annotation at apply time
# (the file stays a placeholder; '#' sed delimiter because the ARN is full of slashes):
HUB_ROLE_ARN=$(cd ../landing-zone/live/aws/fleet/us-west-2/hub/fleet-hub && terragrunt output -raw hub_role_arn)
sed "s#eks.amazonaws.com/role-arn: .*#eks.amazonaws.com/role-arn: ${HUB_ROLE_ARN}#" \
  config/bootstrap/providers.yaml | kubectl apply -f -    # provider + runtime config (60m timeout, 1m poll)
kubectl apply -f config/functions.yaml                    # function-go-templating + function-auto-ready
kubectl -n crossplane-system wait --for=condition=Healthy provider/provider-opentofu --timeout=300s
kubectl apply -f config/providers/providerconfig.yaml     # the single ClusterProviderConfig (source None -> ambient IRSA)

# the Cluster API
kubectl create namespace platform
kubectl apply -f apis/cluster/definition.yaml
kubectl apply -f compositions/cluster-aws.yaml
```

**Validate:**
- `kubectl get provider.pkg.crossplane.io provider-opentofu -o wide` → `Healthy=True`.
- `kubectl get xrd clusters.fleet.nanohype.dev` + `kubectl get composition cluster-aws` present.

The hub can now vend.

## 5. Smoke-vend one cluster (same-account)

The simplest first vend is same-account (into the fleet account itself) — no vend
role needed. Apply a `Cluster` in the `platform` namespace:

```yaml
# smoke.yaml
apiVersion: fleet.nanohype.dev/v1alpha1
kind: Cluster
metadata: { name: hub-smoke, namespace: platform }
spec:
  account: "<fleet-account-id>"   # same account; vendRoleArn omitted -> hub's own creds
  region: us-west-2
  environment: development
  # required base name; the EKS cluster becomes <environment>-<clusterName>
  # (development-eks). Validate + tear down per rung-1 §8-9, which references it.
  clusterName: eks
  team: platform
  # the hub role's IAM gate only mints roles carrying its boundary — wire the
  # SSM-published ARN (/eks-fleet/development/fleet-hub/hub_permissions_boundary_arn,
  # also fleet-hub's hub_permissions_boundary_arn output) onto both halves.
  clusterPermissionsBoundaryArn: "arn:aws:iam::<fleet-account-id>:policy/eks-fleet/eks-fleet-hub-boundary"
  operatorPermissionsBoundaryArn: "arn:aws:iam::<fleet-account-id>:policy/eks-fleet/eks-fleet-hub-boundary"
```

```bash
kubectl apply -f smoke.yaml
kubectl get cluster hub-smoke -n platform -o wide
kubectl get workspace                      # the two provider-opentofu Workspaces (-stack / -bootstrap)
```

It reaches Ready in ~20–40 min. Validate + tear down per `rung-1-local-validation.md`
§8–9 (same checks — real-EKS hub instead of kind). For **cross-account** vending
into a workload spoke, provision `components/aws/fleet-vend` in that account and set
`spec.vendRoleArn` + the boundary fields (the SSM-published
`vend_permissions_boundary_arn`) — see `production-go-live.md` Stage 2.

## Next

- Vend a standing cluster, bootstrap its addons, bring tenants live →
  `production-go-live.md` Stages 2–4.
- Deploy portal on the hub → `portal/docs/deploy-on-hub.md`.

## Teardown

Reverse order: delete any `Cluster`s (wait for both Workspaces to clear), then
`terragrunt destroy` each component (fleet-hub → cluster-bootstrap → cluster →
network), then the state bucket, then `cloudgov orphans --profile fleet` to sweep
residue (EKS log groups, Karpenter SQS/EventBridge — `tofu destroy` misses those).
Confirm zero EKS/NAT/VPC/EC2/EBS/ELB/EIP before walking away.
