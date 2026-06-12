# Rung 1 via portal — vend the spoke from the order desk (local portal → kx hub)

The same loop as [`rung-1-local-validation.md`](./rung-1-local-validation.md), but instead of the
raw `kubectl apply` (rung-1 step 6) you **order the cluster in portal's UI**. Portal renders the
`Cluster` CR and commits it to the **clusters** GitOps repo; ArgoCD on the kx hub applies it;
Crossplane vends. Portal runs **locally** (`task dev`) — the fastest loop, and the same environment
you'll iterate the UI in. No code changes — config + a deploy key + one ApplicationSet.

Portal never touches the cluster directly: it's a hub-side order desk that pushes a `Cluster` CR to
git. It does **not** run in the spoke.

**Cost:** ~$0.40 for the ephemeral vended spoke (same as rung-1) — setup is free. **Time:** ~10-15
min wiring + the ~20-40 min EKS build.

## Prereqs

- **Rung-1 steps 0–5 done** — the kx hub is up with Crossplane v2 + provider-opentofu + the
  `aws-creds` Secret + the `Cluster` API + composition. This runbook **replaces rung-1 step 6**;
  steps 0–5 are not repeated here.
- The **clusters GitOps repo**: `git@github.com:nanohype/clusters.git` (private; checked out at
  `../clusters`).
- **Git auth on the clusters repo:** the **portal worker (local) reuses your personal SSH key**
  (`~/.ssh/id_ed25519`, which already has push access) — no deploy key needed there. **kx's ArgoCD**
  runs in-cluster and can't see your `~/.ssh`, so it needs its own **read-only deploy key** (minted
  in step 3).
- portal toolchain: Go, Node, Docker (for Postgres), `task`. The same SSO session + us-west-2
  access as rung-1.

> **Where you run things:** portal steps run from the **`portal`** repo; the ArgoCD-wiring step
> references `eks-gitops/`, so run it from the **workspace root** (the dir holding `portal/`, `kx/`,
> `eks-gitops/`). The hub is your **`kind-kx`** context.

## 1. Point portal's worker at the clusters repo (before you start it)

Portal reads config from **environment variables** (`caarlos0/env` — there's no `.env` auto-load), so
export these so the worker that `task dev` starts inherits them:

```bash
export GITOPS_CLUSTERS_REPO_URL=git@github.com:nanohype/clusters.git
export GITOPS_SSH_KEY_PATH="$HOME/.ssh/id_ed25519"         # reuse your personal key — it already has push access
export CLUSTER_WATCHBACK_ENABLED=false                     # in-cluster only; off when local
```

(Or add the same keys to the `dev:worker` `env:` block in `portal/Taskfile.yaml`.)

> Reusing `id_ed25519` means the worker pushes as you — fine for local. go-git reads the key file
> directly, so if your key has a **passphrase**, mint a no-passphrase write deploy key instead and
> point `GITOPS_SSH_KEY_PATH` at it:
> `ssh-keygen -t ed25519 -f ~/.ssh/nanohype-clusters -N "" && gh repo deploy-key add ~/.ssh/nanohype-clusters.pub --repo nanohype/clusters --title portal-clusters-rw --allow-write`

## 2. Bring portal up + log in + seed

From the `portal` repo:

```bash
task db:up        # Postgres in Docker
task dev          # migrate + server :8080 + worker :8081 + web :5173
```

Open <http://localhost:5173> → **Dev Login** (first user gets `owner`). Then seed so the order form
has accounts + region defaults:

```bash
task seed         # AWS org vars + landing-zone workspaces + a pipeline
```

> If the **Provision** form's Account dropdown is empty, add your management account (the `seed`
> `LZ_ACCOUNT` env, or the Variables/Accounts view). *Verify on first run.*

## 3. Wire kx's ArgoCD to apply what portal commits

The hub's ArgoCD needs a **read credential** for the clusters repo and the **`clusters`
ApplicationSet**. From the workspace root:

```bash
kubectl config use-context kind-kx

# mint a read-only deploy key for ArgoCD + register it on the repo:
ssh-keygen -t ed25519 -f ~/.ssh/nanohype-clusters-ro -N "" -C "argocd-clusters-ro"
gh repo deploy-key add ~/.ssh/nanohype-clusters-ro.pub --repo nanohype/clusters --title argocd-clusters-ro

# (a) register the clusters repo with ArgoCD (the deploy key's PRIVATE half):
kubectl create secret generic clusters-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:nanohype/clusters.git \
  --from-file=sshPrivateKey="$HOME/.ssh/nanohype-clusters-ro"
kubectl label secret clusters-repo -n argocd argocd.argoproj.io/secret-type=repository

# (b) the AppProject the appset templates (project: platform). Without it the
#     appset errors "AppProject 'platform' not found" and generates NO Application —
#     so the CR sits on GitHub and nothing vends. On a real hub the bootstrap
#     creates this; on kx you apply it yourself.
kubectl apply -f - <<'PROJ'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform project — clusters + addons (kx local hub)
  sourceRepos: ["*"]
  destinations:
    - { server: "*", namespace: "*" }
  clusterResourceWhitelist:
    - { group: "*", kind: "*" }
  namespaceResourceWhitelist:
    - { group: "*", kind: "*" }
PROJ

# (c) the ApplicationSet (from eks-gitops):
kubectl apply -f eks-gitops/applicationsets/clusters-appset.yaml
```

> The appset is a **git-directory generator over `clusters/*`** → one Application per environment
> dir, applied to the in-cluster hub with prune+selfHeal. The portal worker writes
> `clusters/<env>/<name>.yaml`, so the paths line up. **This appset has been static-validated but
> never run on a live hub** — after your first order, eyeball the `clusters-dev` Application
> (Synced/Healthy) and confirm it only reconciles on the hub (kx is your only cluster here, so
> fine). *Verify on first use.*

## 4. Vend via the portal UI

`/clusters` → **Provision Cluster**:

| Field | Value |
| --- | --- |
| Account | your management account |
| Region | `us-west-2` |
| Team | `platform` |
| Environment | `dev` |
| Kubernetes version | `1.35` |
| Public API endpoint | your call |

Submit → `202`. The worker renders the `Cluster` CR and pushes `clusters/dev/<name>.yaml` to the
clusters repo. **Real spend begins once ArgoCD applies it and Crossplane starts the build.**

## 5. Watch the loop close

```bash
# the order: portal UI shows the operation 'committed' (+ a git SHA); the file lands in the repo.
kubectl get applications -n argocd | grep clusters     # the clusters-dev Application syncs
kubectl get cluster,workspace -n platform              # the Cluster XR + the two Workspaces
kubectl describe workspace                             # tofu plan/apply progress
aws eks describe-cluster --name dev-eks --region us-west-2   # ACTIVE in ~20-40 min
```

> `cluster-watchback` is off (local portal), so the UI won't flip the order to **active** or show
> the spoke's live status — expected. Watch it with `kubectl`. (Live status in the UI is the
> in-cluster topology, or a later UI change.)

## 6. Teardown / verify zero-billable

**Deprovision** in portal (or `git rm clusters/dev/<name>.yaml` in the clusters repo + push).
prune+selfHeal deletes the `Cluster` → Crossplane `tofu destroy` (the teardown Usage orders
bootstrap-before-stack, same as rung-1):

```bash
kubectl get workspace -w                         # wait until BOTH are gone
aws eks list-clusters --region us-west-2          # []
```

Then sweep residue the destroy can't reach (EKS log group, Karpenter) with `cloudgov` / the
eks-fleet reap logic — same note as rung-1 step 9. Bring the hub down when done:
`(cd ../kx && task down)`.

## Notes

- **No code changes** — this is config + a deploy key + one ApplicationSet on top of rung-1's hub.
- The UI you'll iterate on lives in `portal/web/src/components/cluster/` (`ClusterOrderModal.tsx`,
  `ClusterList.tsx`, `ClusterDetail.tsx`). `task dev`'s Vite HMR is live, so UI edits show instantly
  — no rebuild, no redeploy.
