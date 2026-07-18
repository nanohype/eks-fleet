# Runbook: vend failure

Triage for the `fleet-vend` Grafana alerts — `FleetVendReconcileFastBurn`,
`FleetVendReconcileSlowBurn`, `FleetVendProviderAbsent`. These watch the
provider-opentofu controller-runtime reconcile metrics on the hub
(`controller_runtime_*{namespace="crossplane-system"}`); the SLO is "99% of vend
reconciles succeed over 30d". A vend is a `Cluster` (`fleet.nanohype.dev`) →
provider-opentofu `Workspace` (`opentofu.m.upbound.io`) → `tofu` against the
landing-zone cluster-stack.

All commands run against the **hub** cluster (`kubectl` context = the hub).

## FleetVendProviderAbsent — the provider is down or unscraped

The reconcile metrics vanished. The hub can't vend or reconcile any cluster.

```bash
kubectl -n crossplane-system get pods -l pkg.crossplane.io/provider=provider-opentofu
kubectl -n crossplane-system logs deploy/provider-opentofu --tail=100
kubectl get providers.pkg.crossplane.io                 # provider Healthy/Installed conditions
```

- **CrashLoop / not Ready** → read the logs for the cause (bad package ref, RBAC,
  OOM). Check `kubectl -n crossplane-system describe pod <provider-pod>`.
- **Running but no metrics** → the scrape broke. Confirm the pod still carries
  `prometheus.io/scrape: "true"` on `:8080` (set in `config/bootstrap/providers.yaml`)
  and that grafana-agent is scraping it. If the pod is healthy and serving
  `/metrics`, this is an observability-side problem, not a vend problem.

## FleetVendReconcile{Fast,Slow}Burn — vends are failing

Reconcile errors are burning the error budget (FastBurn = 14.4× over 1h∧5m, page;
SlowBurn = 6× over 6h∧30m, page). One or more Workspaces are failing to apply.

### 1. Find the failing Workspace(s)

```bash
# Workspaces not Synced/Ready are the failing vends.
kubectl get workspace -A -o wide
kubectl get workspace -A -o json | jq -r '
  .items[] | select(
    (.status.conditions // []) | any(.type=="Synced" and .status!="True")
  ) | .metadata.name'
```

### 2. Read the real error (the tofu/AWS message)

The `Synced=False` condition message carries the actual `tofu plan`/`apply` error —
this is the root cause, not the burn rate.

```bash
kubectl get workspace <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'
```

Common shapes:

- **AWS API error** (quota, IAM denied, capacity) → fix the underlying AWS
  condition; the Workspace re-applies on the next reconcile.
- **tofu state lock / backend error** → the S3 backend
  (`fleet/<namespace>/<name>/terraform.tfstate`, locked S3-natively via `use_lockfile`)
  is locked or unreachable. Confirm the state bucket + the Workspace's
  `initArgs` backend-config.
- **Module/source error** → the landing-zone cluster-stack entrypoint (the
  `https://` git source) changed or is unreachable.

Provider logs scoped to the Workspace give the full apply output:

```bash
kubectl -n crossplane-system logs deploy/provider-opentofu | grep -A20 "<name>"
```

### 3. Budget-burn response

FastBurn pages because the 30d budget drains in hours at this rate. If the failure
is a single bad `Cluster` spec (not a systemic provider/AWS outage), the blast
radius is that one vend — fix or delete the offending `Cluster` and the burn
clears. If it's systemic (every vend failing — provider creds expired, AWS region
down), treat it as a hub outage.

## Stuck create / delete (external-create-pending deadlock)

If a Workspace is wedged in `external-create-pending` (vend started, never
converged), it blocks **both** create and delete, and a naive
`kubectl delete cluster` will hang. **Do not cycle the provider pod mid-apply** —
that orphans an empty-state vend (live AWS, empty S3 state). Recovery is to drop
the Workspace finalizer and delete the AWS resources directly. See the teardown
procedure (reverse order: `Cluster`s → Workspaces clear → network → state bucket →
`cloudgov orphans --profile fleet` to sweep) in
[stand-up-the-hub.md](../stand-up-the-hub.md#teardown).

## After it clears

The reconcile-success rate recovers on the next successful reconciles; the burn
alerts auto-resolve once the ratio drops back under the threshold for the `for`
window. Confirm on the `eks-fleet — vend pipeline` dashboard.
