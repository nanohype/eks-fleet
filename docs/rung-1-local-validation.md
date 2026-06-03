# Rung 1 — prove the factory loop on a local kind hub

The cheap end-to-end proof: a `Cluster` claim manufactures one **real** EKS cluster,
the status fills in, then it tears down — with the management hub running on a
**local kind cluster (kx)** instead of a persistent $70/mo EKS hub. Validates the
whole loop (claim → Composition → provider-terraform Workspace → cluster-stack
entrypoint → real EKS → status) before committing to the production hub (rung 0).

**Cost:** ~$0.40 for the ephemeral vended cluster (torn down at the end). The hub
is free (local kind). **Time:** ~45 min, most of it the EKS build.

## Prereqs

- `kx` workspace, `helm`, `kubectl`, the `crossplane` CLI, `tofu`.
- A live SSO session (`aws sts get-caller-identity --profile fleet-admin`). The hub
  authenticates with temp creds from this session, so **finish within its lifetime**.
- Bedrock/region access in us-west-2 (same as the e2e).

## 0. One-time: the fleet state backend

provider-terraform persists state in S3 (not the pod). Create the fleet bucket
once in the management account (111111111111):

```bash
aws s3 mb s3://nanohype-eks-fleet-tfstate --region us-west-2
aws s3api put-bucket-versioning --bucket nanohype-eks-fleet-tfstate \
  --versioning-configuration Status=Enabled
# locking: S3 native (use_lockfile) — no DynamoDB table needed.
```

## 1. Bring up the hub (kx)

```bash
cd ../kx && task up      # local kind cluster
kubectl config use-context kind-kx
```

## 2. Install Crossplane + provider-terraform + the function

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace

kubectl apply -f config/local/providers.yaml   # provider-terraform (no IRSA, 60m timeout)
kubectl apply -f config/functions.yaml          # function-patch-and-transform
kubectl -n crossplane-system wait --for=condition=Healthy provider/provider-terraform --timeout=300s
```

## 3. AWS credentials (the kind-vs-EKS difference)

kind has no IRSA, so the hub reads temp creds from a Secret:

```bash
eval "$(aws configure export-credentials --profile fleet-admin --format env)"
kubectl create secret generic aws-creds -n crossplane-system \
  --from-literal=credentials="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\naws_session_token=%s\n' \
    "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN")"

kubectl apply -f config/local/providerconfig.yaml   # Secret-cred ProviderConfig (name: default)
```

## 4. Install the Cluster API + composition

```bash
kubectl apply -f apis/cluster/definition.yaml
kubectl apply -f compositions/cluster-aws.yaml
```

## 5. Vend a cluster (the real-spend step)

A same-account claim — `account` is the management account, `vendRoleArn` omitted
so the hub provisions with its own creds (no cross-account assume):

```yaml
# rung1-claim.yaml
apiVersion: fleet.nanohype.dev/v1alpha1
kind: Cluster
metadata: { name: fleet-smoke, namespace: default }
spec:
  account: "111111111111"
  region: us-west-2
  environment: dev
  team: platform
  # vendRoleArn omitted -> same-account, uses the hub's creds
```

```bash
kubectl apply -f rung1-claim.yaml
```

## 6. Watch

```bash
kubectl get cluster fleet-smoke -o wide                       # the claim
kubectl get workspace                                          # the provider-terraform MR
kubectl describe workspace                                     # tofu plan/apply progress
kubectl get cluster fleet-smoke -o jsonpath='{.status}' | jq   # endpoint/OIDC fill in
```

The Workspace runs `tofu init` (fetching `landing-zone//fleet/cluster-stack`, public)
→ `apply` → ~20-40 min for the EKS build.

## 7. Validate

- `kubectl get cluster fleet-smoke` shows the status populated (`clusterEndpoint`,
  `oidcProviderArn`, `oidcIssuer`, `vpcId`).
- `aws eks describe-cluster --name dev-eks --region us-west-2` → ACTIVE.
- (optional) point `cloudgov` at it.

## 8. Teardown + verify zero-billable

```bash
kubectl delete cluster fleet-smoke      # provider-terraform runs tofu destroy
kubectl get workspace -w                # wait until gone
# confirm:
aws eks list-clusters --region us-west-2          # []
aws ec2 describe-vpcs --filter Name=tag:Project,Values=landing-zone Name=tag:Environment,Values=dev Name=isDefault,Values=false
cd ../kx && task down                   # tear down the local hub
```

If the vended cluster orphans anything (it shouldn't — the entrypoint is the same
modules the e2e tore down cleanly), the e2e harness's reaping logic in
`landing-zone/scripts/e2e.sh` is the reference.

## Verify on first run (design gaps to close while executing)

- **Cred wiring** — confirm provider-terraform actually exposes the `aws-creds`
  Secret to the tofu run (it should write the file + set `AWS_SHARED_CREDENTIALS_FILE`).
  If the provider can't find creds, switch to env-var creds injected via the
  DeploymentRuntimeConfig instead of the Secret file.
- **Backend locking** — confirm the S3 backend init succeeds with native locking;
  if it wants a lock table, add `use_lockfile=true` to the Composition's backendConfig.
- **SSO expiry** — if the session expires mid-build, refresh it and recreate the
  `aws-creds` Secret; provider-terraform picks it up on the next reconcile.
- **Outputs → status** — confirm `ToCompositeFieldPath` populates the claim status
  (a known Crossplane nuance — may take an extra reconcile after apply completes).
