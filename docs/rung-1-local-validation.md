# Rung 1 — prove the factory loop on a local kind hub

The cheap end-to-end proof: a namespaced `Cluster` manufactures one **real** EKS
cluster, the status fills in, then it tears down — with the management hub running
on a **local kind cluster (kx)** instead of a persistent $70/mo EKS hub. Validates
the whole loop (`Cluster` → Composition → provider-opentofu Workspace → cluster-stack
entrypoint → real EKS → status) before committing to the production hub (rung 0).

**Cost:** ~$0.40 for the ephemeral vended cluster (torn down at the end). The hub
is free (local kind). **Time:** ~45 min, most of it the EKS build.

## Prereqs

- `kx` workspace, `helm`, `kubectl`, the Crossplane v2 `crossplane` CLI, `tofu`.
- A live SSO session (`aws sts get-caller-identity --profile fleet-admin`). The hub
  authenticates with temp creds from this session, so **finish within its lifetime**.
- Bedrock/region access in us-west-2 (same as the e2e).

## 0. One-time: the fleet state backend

provider-opentofu persists state in S3 (not the pod). Create the fleet bucket
once in the management account (111111111111 — your mgmt account):

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

## 2. Install Crossplane v2

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace --version 2.3.1
kubectl -n crossplane-system rollout status deploy/crossplane --timeout=180s
```

## 3. AWS credentials (the kind-vs-EKS difference) — BEFORE the provider

kind has no IRSA. The local provider runtime (step 4) mounts the `aws-creds` Secret
and points the AWS SDK at it (`AWS_SHARED_CREDENTIALS_FILE`), so the Secret must exist
**before** the provider pod starts:

```bash
eval "$(aws configure export-credentials --profile fleet-admin --format env)"
kubectl create secret generic aws-creds -n crossplane-system \
  --from-literal=credentials="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\naws_session_token=%s\n' \
    "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN")"
```

## 4. Install provider-opentofu + the function + the ClusterProviderConfig

```bash
kubectl apply -f config/local/providers.yaml        # provider-opentofu; mounts aws-creds, 60m timeout, 1m poll
kubectl apply -f config/functions.yaml              # function-go-templating + function-auto-ready
kubectl -n crossplane-system wait --for=condition=Healthy provider/provider-opentofu --timeout=300s
kubectl apply -f config/local/providerconfig.yaml   # ClusterProviderConfig (source None; creds via the pod env)
```

## 5. Install the Cluster API + composition

```bash
kubectl create namespace platform
kubectl apply -f apis/cluster/definition.yaml
kubectl apply -f compositions/cluster-aws.yaml
```

> The Workspace fetches `landing-zone` at `?ref=main` and runs `tofu` in the
> `fleet/aws/cluster-stack` subdir (the composition's `entrypoint`). provider-opentofu
> v1.1.3 ships tofu 1.10.0, so `main` must carry the `>= 1.10.0` floor. Apply a fresh
> `Cluster` (don't mutate one in place — `remotePullPolicy: IfNotPresent` caches the
> working dir, and a pod roll mid-apply orphans resources from the Workspace's state).

## 6. Vend a cluster (the real-spend step)

A same-account `Cluster` — `account` is the management account, `vendRoleArn`
omitted so the hub provisions with its own creds (no cross-account assume). Under
Crossplane v2 this namespaced `Cluster` is the resource you apply directly; it
lands in the `platform` namespace:

```yaml
# rung1-cluster.yaml
apiVersion: fleet.nanohype.dev/v1alpha1
kind: Cluster
metadata: { name: fleet-smoke, namespace: platform }
spec:
  account: "111111111111"  # your management account
  region: us-west-2
  environment: dev
  team: platform
  # vendRoleArn omitted -> same-account, uses the hub's creds
```

```bash
kubectl apply -f rung1-cluster.yaml
```

## 7. Watch

```bash
kubectl get cluster fleet-smoke -n platform -o wide               # the namespaced Cluster
kubectl get workspace                                             # the provider-opentofu MRs (two)
kubectl describe workspace                                        # tofu plan/apply progress
kubectl get cluster fleet-smoke -n platform -o jsonpath='{.status}' | jq   # endpoint/OIDC fill in
```

The composition renders **two** Workspaces. First `cluster-stack` runs `tofu init`
(fetching the public `landing-zone` repo, running in the `fleet/aws/cluster-stack`
subdir) → `apply` → ~20-40 min for the EKS build. Once it publishes the cluster
endpoint to `Cluster.status`, the `function-go-templating` step renders the second
`cluster-bootstrap` Workspace (`fleet/aws/cluster-bootstrap`), which installs Cilium +
ArgoCD + the eks-agent-platform operator onto the new cluster; `function-auto-ready`
marks the `Cluster` Ready once both converge.

## 8. Validate

- `kubectl get cluster fleet-smoke -n platform` shows the status populated
  (`clusterEndpoint`, `oidcProviderArn`, `oidcIssuer`, `vpcId`).
- `aws eks describe-cluster --name dev-eks --region us-west-2` → ACTIVE.
- The `cluster-bootstrap` Workspace converged: `kubectl --kubeconfig <vended> get pods -n kube-system | grep cilium` and `-n argocd` show the addons (and the operator) installed by the second Workspace.
- (optional) point `cloudgov` at it.

## 9. Teardown + verify zero-billable

```bash
kubectl delete cluster fleet-smoke -n platform   # provider-opentofu runs tofu destroy
# A teardown Usage orders it: cluster-bootstrap destroys before cluster-stack, so
# the addons come off the cluster before the cluster itself is torn down.
kubectl get workspace -w                # wait until BOTH workspaces are gone
# confirm:
aws eks list-clusters --region us-west-2          # []
aws ec2 describe-vpcs --filter Name=tag:Project,Values=landing-zone Name=tag:Environment,Values=dev Name=isDefault,Values=false
cd ../kx && task down                   # tear down the local hub
```

If the vended cluster orphans anything (it shouldn't — the entrypoint is the same
modules the e2e tore down cleanly), the e2e harness's reaping logic in
`landing-zone/scripts/e2e.sh` is the reference.

## Verify on first run (design gaps to close while executing)

- **Cred wiring (resolved)** — `source: Secret`'s written creds file isn't picked up by
  the AWS SDK, so the local runtime config mounts the `aws-creds` Secret and sets
  `AWS_SHARED_CREDENTIALS_FILE` (the ProviderConfig is `source: None`). This is wired in
  `config/local/`; the Secret must exist before the provider pod starts (step 3).
- **Backend locking** — confirm the S3 backend init succeeds with native locking;
  if it wants a lock table, add `-backend-config=use_lockfile=true` to the
  Workspace's `initArgs`.
- **SSO expiry** — if the session expires mid-build, refresh it and recreate the
  `aws-creds` Secret; provider-opentofu picks it up on the next reconcile.
- **Outputs → status** — confirm the composition's status write-back populates the
  `Cluster` status from the cluster-stack Workspace's tofu outputs (a known Crossplane
  nuance — may take an extra reconcile after apply completes; the `--poll=1m` runtime
  arg keeps it from lagging the 10m default).
