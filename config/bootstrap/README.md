# Hub-cluster bootstrap

What turns a plain EKS cluster into the `eks-fleet` hub. In the real flow an
`eks-gitops` ApplicationSet syncs all of this; the steps below are the manual
equivalent + the order they must happen in.

## 1. The hub cluster

A dedicated EKS cluster in the `fleet` account, stood up by `landing-zone`
the same way any other cluster is (it's the one cluster you *do* hand-author,
because it's the thing that vends the rest). It runs Crossplane v2 +
provider-opentofu + ArgoCD.

## 2. The hub identity (IRSA + state backend) — in `landing-zone`

Provision in the fleet account:
- An IAM OIDC provider for the hub cluster.
- Role `eks-fleet-crossplane`, trusting `system:serviceaccount:crossplane-system:provider-opentofu`,
  allowed to (a) read/write the fleet tfstate bucket, and (b)
  `sts:AssumeRole` into each workload account's vend role.
- The `nanohype-eks-fleet-tfstate` S3 bucket (versioned, encrypted; S3 native
  locking via `use_lockfile`, no DynamoDB table).

Put the role ARN in `providers.yaml`'s ServiceAccount annotation — it lands on the
`provider-opentofu` ServiceAccount as `eks.amazonaws.com/role-arn`, the ambient
IRSA the provider pod runs as.

## 3. Install Crossplane

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace
```

## 4. Install the provider + function

```bash
kubectl apply -f providers.yaml          # provider-opentofu + runtime config
kubectl apply -f ../functions.yaml       # function-go-templating + function-auto-ready
```

## 5. The hub ClusterProviderConfig (single, source None)

```bash
kubectl apply -f ../providers/providerconfig.yaml
```

One cluster-scoped `default` `ClusterProviderConfig` serves every account. Its
`credentials: [{filename: aws-creds.ini, source: None}]` writes no creds file —
the provider pod's ambient IRSA (the `provider-opentofu` ServiceAccount's
`eks.amazonaws.com/role-arn`) supplies the AWS SDK credential chain. The hub's IRSA
provisions in its own account and `sts:AssumeRole`s a workload's `fleet-vend` role
for the rest. Cross-account targeting rides on the `Cluster` (`spec.account` →
`spec.vendRoleArn` → the entrypoint's `assume_role`), so there's no per-account
ProviderConfig to add.

## 6. The Cluster API + composition

```bash
kubectl apply -f ../../apis/cluster/definition.yaml
kubectl apply -f ../../compositions/cluster-aws.yaml
```

Now a namespaced `Cluster` applied to the hub cluster vends a workload
cluster.

## 7. The ephemeral-spoke reaper

```bash
kubectl apply -f ../reaper.yaml
```

An hourly CronJob (in `crossplane-system`) that deletes `Cluster` CRs whose
`spec.ttlDays` has elapsed since creation — only `ttlDays > 0` clusters are
candidates, persistent clusters are never touched. Deleting the CR triggers the
composition's ordered `tofu destroy`, so ephemeral vends tear down cleanly on
schedule and leave no orphans behind.

Because each delete tears down a real EKS cluster, the reaper ships safe:

- **`DRY_RUN=true` (default)** — it logs which clusters it would reap and deletes
  nothing. Watch a cycle or two (`kubectl logs -n crossplane-system job/...`),
  confirm only genuinely-expired ephemeral spokes appear, then set `DRY_RUN=false`
  in `reaper.yaml` to arm it (a reviewable GitOps change).
- **`MAX_REAP=5`** — the most clusters one run may delete. A clock skew or a
  mis-set `ttlDays` could flag many live clusters at once; if more than `MAX_REAP`
  are expired, the job refuses to act and exits non-zero. That surfaces as a
  failed Job (`kube_job_failed`) for alerting instead of a silent mass-deletion.
