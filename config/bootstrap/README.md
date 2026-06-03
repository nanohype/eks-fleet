# Management-cluster bootstrap

What turns a plain EKS cluster into the `eks-fleet` hub. In the real flow an
`eks-gitops` ApplicationSet syncs all of this; the steps below are the manual
equivalent + the order they must happen in.

## 1. The management cluster

A dedicated EKS cluster in the `management` account, stood up by `landing-zone`
the same way any other cluster is (it's the one cluster you *do* hand-author,
because it's the thing that vends the rest). It runs Crossplane + provider-terraform
+ ArgoCD.

## 2. The hub identity (IRSA + state backend) — in `landing-zone`

Provision in the management account:
- An IAM OIDC provider for the management cluster.
- Role `eks-fleet-crossplane`, trusting `system:serviceaccount:crossplane-system:provider-terraform`,
  allowed to (a) read/write the fleet tfstate bucket + lock table, and (b)
  `sts:AssumeRole` into each workload account's vend role.
- The `nanohype-eks-fleet-tfstate` S3 bucket (versioned, encrypted) + a lock table.

Put the role ARN in `providers.yaml`'s ServiceAccount annotation.

## 3. Install Crossplane

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace
```

## 4. Install the provider + function

```bash
kubectl apply -f providers.yaml          # provider-terraform + runtime config
kubectl apply -f ../functions.yaml       # function-patch-and-transform
```

## 5. The hub ProviderConfig (single, InjectedIdentity)

```bash
kubectl apply -f ../providers/providerconfig.yaml
```

One `default` ProviderConfig serves every account — the hub's IRSA provisions in
its own account and `sts:AssumeRole`s a workload's `fleet-vend` role for the rest.
Cross-account targeting rides on the claim (`spec.account` → the entrypoint's
`assume_role_arn`), so there's no per-account ProviderConfig to add.

## 6. The Cluster API + composition

```bash
kubectl apply -f ../../apis/cluster/definition.yaml
kubectl apply -f ../../compositions/cluster-aws.yaml
```

Now a `Cluster` claim applied to the management cluster vends a workload cluster.
