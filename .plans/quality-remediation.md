# Quality remediation — eks-fleet

Tactical plan for this repo's targets in the org quality-remediation campaign.
Master plan: `~/.claude/plans/quality-remediation.md` (read its loop protocol and
decision ledger first).

This repo joined the campaign 2026-07-18 via its first-ever `/quality-check` audit
(no prior baseline). Grades: architecture A-, patterns A-, systems B-, testing C+,
frontend N/A, security A-, code_quality B-, documentation B, consistency B+,
ai_systems B+. Clean architecture and security, but **`main` is currently broken
for every vend** — the network-idiom composition sends tofu vars its pinned
landing-zone SHA doesn't declare.

## Status

| # | target | status |
|---|---|---|
| 27 | CRITICAL: fix the broken `moduleSource` pin | ✅ #17 |
| 33 | State integrity + doc fixes | ✅ #18 |

---

## Target 27 — CRITICAL: fix the broken moduleSource pin (S)

`main` cannot vend a cluster today. The network-idiom schema (top commit
`22e2e09`) templates `network_mode`, `ipam_pool_id`, `ipam_netmask_length`,
`transit_gateway_id`, `centralized_egress`, `adopt_vpc_id`,
`adopt_private_subnet_ids`, `adopt_public_subnet_ids` onto cluster-stack
(`compositions/cluster-aws.yaml:102-112`) and
`network_mode`/`private_subnet_ids`/`public_subnet_ids` onto cluster-bootstrap
(`cluster-aws.yaml:184-186`), but `moduleSource` in both
`apis/cluster/definition.yaml:307` and `cluster-aws.yaml:55` still pins
landing-zone `1ae86cc` — verified directly via
`git -C ../landing-zone show 1ae86cc:fleet/aws/cluster-stack/variables.tf`: none
of those variables exist at that commit (they landed two commits later,
`19625ea`; the resource-naming semantics change `ddaf3ee` is also past the pin).
Every vend from current `main` fails at `tofu plan` with undeclared-variable
errors. No CI gate touches the composition↔substrate contract —
`crossplane render` never runs tofu — which is how this merged silently.

Findings (verified):
- `apis/cluster/definition.yaml:307` and `compositions/cluster-aws.yaml:55` both
  pin `1ae86cc` (kept in lockstep with each other, per the comments, but not
  rolled forward with the schema change that requires the newer substrate).
- The per-repo network-idiom plan (`.plans/network-idiom.md:106-116`) says var
  names were "verified against the merged landing-zone source" — verified
  against landing-zone HEAD, not against the SHA the Workspace actually fetches.
- `docs/rung-1-local-validation.md:92` cites provider v1.1.3 against the pinned
  v1.1.4 in `config/bootstrap/providers.yaml:9` (adjacent version-drift, fix in
  passing).

Approach:
1. Bump `moduleSource` to a landing-zone SHA ≥ `19625ea` (post-network-idiom,
   post-`ddaf3ee` naming-semantics) in both `apis/cluster/definition.yaml:307`
   and `compositions/cluster-aws.yaml:55` — lockstep, verified equal after the
   edit.
2. Add a CI job that greps both pins for equality (fail if they diverge) and
   diffs the composition's templated var keys (both cluster-stack and
   cluster-bootstrap blocks) against
   `git show <pin>:fleet/aws/cluster-{stack,bootstrap}/variables.tf` from a
   landing-zone checkout — fail if the composition sends a var the pinned
   commit doesn't declare. This is the gate that would have caught this; it's
   the permanent fix, not just the pin bump.
3. Fix the adjacent provider version-floor doc drift.

Acceptance: `crossplane render` continues to pass (unchanged); a real
`tofu plan` against the pinned substrate (or the new CI contract-check job, if
a live AWS plan isn't feasible in CI) succeeds with the network-idiom vars; the
new CI job fails if the pin is bumped without the vars matching, and fails if
the vars are extended without the pin following — prove both directions.

**Outcome (✅ #17):** Pinned both `moduleSource` defaults (lockstep) to
landing-zone `9243a18` — current `main` HEAD, not the plan's suggested
`19625ea`. Verified directly: `19625ea` only declares the network vars on
*cluster-stack*; cluster-bootstrap's `network_mode`/`private_subnet_ids`/
`public_subnet_ids` don't land until `dd9ba8b`, so `19625ea` would still break
the second Workspace. HEAD declares every variable the composition sends across
both entrypoints.

Rolling the pin forward surfaced two **additional** contract gaps beyond the
network-idiom undeclared vars — the same drift class, opposite direction
(required-but-not-sent), that the audit's send-side analysis missed:
`data_kms_key_arn` (added upstream in `520e1c2`) and `gitops_repo_url` (added in
`ee7e732`) are both required cluster-bootstrap inputs with no substrate default,
and the composition never sent either. Both are spoke prerequisites referenced
by ARN/URL (same shape as `vendRoleArn`/boundaries), so added
`spec.dataKmsKeyArn` (default `""`), `spec.gitopsRepoUrl` (default the org
eks-gitops catalog), and `spec.gitopsRepoBranch` (default `main`) to the XRD and
templated them onto the bootstrap Workspace. Without these, a vend would clear
cluster-stack and then fail at cluster-bootstrap plan — main still couldn't
complete a vend.

The permanent gate is `scripts/check-substrate-contract.py` + the
`substrate-contract` CI job (+ `task contract`): at the pinned SHA it fetches
each entrypoint's `variables.tf`, diffs it against the composition's templated
var keys (fails on undeclared **and** on missing-required), and asserts the two
pins are byte-equal. Proven to fail in all directions (pin divergence,
undeclared var, omitted required var) and to flag the exact eight network-idiom
vars when replayed at the old `1ae86cc` pin. Also fixed the adjacent
provider/tofu version-floor doc drift (`docs/rung-1-local-validation.md`, v1.1.3/
1.10.0 → v1.1.4/1.10.8). Verified with `crossplane render` (all examples,
unchanged), `tofu validate` on both pinned entrypoints, and a real `tofu plan`
fed the composition's exact cluster-stack vars (zero undeclared/missing-variable
errors; stops only at AWS credential resolution).

Scope note: `data_kms_key_arn` and `gitops_repo_url` are now supplied by the
order desk via spec fields (the spoke's baseline already publishes the CMK to
SSM `/platform/<env>/secrets/kms-key-arn`). The fleet flow still has no
component that *creates* a per-spoke data CMK — cluster-stack provisions only
network + cluster — so a fully autonomous vend assumes the spoke's secrets
baseline exists, exactly as it assumes the fleet-vend role + boundaries do.
That's consistent with the fleet's prerequisite model, not a new gap.

## Target 33 — State integrity + doc fixes (M)

Findings (verified):
- No tofu state locking is actually configured: the entrypoints' backend blocks
  are empty partials (`landing-zone/fleet/aws/cluster-stack/versions.tf:17`),
  and the composition's `initArgs` pass only bucket/key/region/encrypt
  (`compositions/cluster-aws.yaml:139-143,193-197`) — no `use_lockfile=true`,
  no DynamoDB table. `docs/rung-1-local-validation.md:178-180` already lists
  this as an unverified open item; `config/bootstrap/README.md:21-23` asserts
  S3-native locking as fact, contradicting that.
- Cross-namespace state-key collision: the S3 state key is
  `fleet/{{ $name }}/terraform.tfstate` keyed on `metadata.name` alone
  (`cluster-aws.yaml:141,195`) — two Clusters named the same in two team
  namespaces (legal, and the advertised usage model per `README.md:26-28`)
  share one state object. `docs/architecture.md:104`'s "every Cluster gets an
  isolated state object" claim is false across namespaces.
- Backend region coupled to `spec.region`: the static bucket
  `nanohype-eks-fleet-tfstate` lives in us-west-2, but
  `-backend-config=region={{ $spec.region }}` follows the cluster's region
  (`cluster-aws.yaml:142,196`) — any vend with `spec.region` != us-west-2 fails
  `tofu init` (S3 backend validates bucket region), and the constraint is
  documented nowhere; `spec.region` has no enum/validation
  (`definition.yaml:32-34`).
- Both canonical walkthrough docs' sample manifests omit the now-required
  `clusterName`: `rung1-cluster.yaml` (`docs/rung-1-local-validation.md:103-117`)
  and `smoke.yaml` (`docs/stand-up-the-hub.md:124-139`) fail admission against
  `definition.yaml:312-316` (required since the naming-standard adoption,
  commit `5148752`); `production-go-live.md:53` repeats the omission in its
  required-fields list.
- `production-go-live.md:54` says "Crossplane fetches `landing-zone@main`" —
  contradicting the pinned-SHA design the composition comments and teardown
  runbook document.
- `.yamllint.yaml:4-5` ignores `catalog/druid/chart/templates/` — a path from
  another repo that exists nowhere in this one (copy-paste residue).
- No negative-path CEL tests exist for the safety rules that are this repo's
  actual guardrails (public-endpoint-with-empty-allowlist rejection, adopt-mode
  preconditions, boundary-ARN requirement) — `crossplane render` doesn't
  evaluate CEL, so nothing in CI proves these rules actually fire.

Approach:
1. Add the namespace to the S3 state key (`fleet/<namespace>/<name>/…`) in
   both `initArgs` blocks — before any second team namespace exists in
   practice.
2. Add `-backend-config=use_lockfile=true` to both `initArgs` blocks; reconcile
   `config/bootstrap/README.md` and `docs/rung-1-local-validation.md` so they
   agree.
3. Either constrain `spec.region` to the state bucket's region (enum or CEL
   validation) or decouple the backend region from `spec.region` entirely (a
   second static bucket per supported region, or a bucket that isn't
   region-pinned) — pick one and document the constraint either way.
4. Fix the sample manifests in both walkthrough docs to include `clusterName`;
   fix `production-go-live.md`'s required-fields list and its `@main`
   sentence; delete the stray druid path from `.yamllint.yaml`.
5. Add CEL negative-path tests — the org's `kx` local kind hub (purpose-built
   for server-side dry-run exercises, per this repo's own docs) is the right
   tool since `crossplane render` can't evaluate CEL; a small scripted suite
   applying deliberately-invalid manifests and asserting admission rejection.

Acceptance: a fresh vend of two same-named Clusters in different namespaces
doesn't collide (prove with a dry-run against two namespaces); state-locking is
real (`tofu init` output shows lock config, or the equivalent S3-native-lock
proof); a `spec.region` outside the supported set either validates cleanly
against a real per-region bucket or is rejected with a clear error, not a
backend-init failure; both walkthrough docs' sample manifests admit cleanly as
written; CEL negative tests run in CI and fail on a deliberately-broken
manifest.

**Outcome (✅ #18):** All five items shipped.

1. **State-key namespacing.** Both Workspace `initArgs` now key on
   `fleet/<namespace>/<name>/terraform.tfstate` (added `$ns` from
   `metadata.namespace` to the template). Confirmed line numbers had shifted from
   Target 27's edits (the cluster-bootstrap block grew with the
   `data_kms_key_arn`/`gitops_repo_*` vars); edited the initArgs blocks by content,
   not line. Proven: same-named `development-platform` rendered in `team-a` vs
   `team-b` → `fleet/team-a/development-platform/...` vs `fleet/team-b/...`.

2. **Locking.** Added `-backend-config=use_lockfile=true` to both blocks (S3-native,
   tofu 1.10.8 that provider-opentofu v1.1.4 ships is past the >= 1.10 floor).
   Reconciled the `config/bootstrap/README.md`-asserts vs `rung-1`-flags-unverified
   contradiction — rung-1's "Backend locking" open item now states it as configured.

3. **Region.** Chose **decouple** over constrain (less disruptive, and constraining
   to one region defeats a multi-region fleet). Backend region is now the static
   bucket region `us-west-2`, no longer `spec.region`, so any region validates
   cleanly against the one real bucket instead of failing `tofu init`. Documented on
   the XRD `region` field, `architecture.md`, `CLAUDE.md`. Proven: `spec.region:
   us-east-1` render → backend region stays `us-west-2` (cluster still built in
   us-east-1 via the `region` tofu var). No conflict with Target 27's XRD additions.

4. **Docs.** Added `clusterName: eks` to the rung-1 (`rung1-cluster.yaml`) and
   stand-up (`smoke.yaml`) samples (→ `development-eks`, matching each doc's
   validation commands); added `clusterName` to `production-go-live.md`'s
   required-fields list; rewrote its "fetches `landing-zone@main`" sentence to the
   pinned-SHA design (given Target 27 just re-pinned it); removed the stray
   `catalog/druid/chart/templates/` ignore from `.yamllint.yaml`. Also updated
   `architecture.md` + the vend-failure runbook to the namespaced key / fixed region.
   Note: the "tofu version-floor drift" the master row mentions was already
   reconciled by Target 27 (all docs consistent at tofu >= 1.10.0 / provider v1.1.4
   / tofu 1.10.8) — nothing left to fix there.

5. **CEL negative tests.** No `kx`/kind validation harness existed for CEL (Target 27
   added only the substrate-contract gate, which doesn't touch CEL). Built one:
   `scripts/xrd-to-crd.py` lifts the XRD's exact `openAPIV3Schema` into a plain CRD
   (byte-identical rules — Crossplane passes `x-kubernetes-validations` through
   verbatim, so no Crossplane install is needed in CI), and
   `scripts/cel-admission-test.sh` stands up a throwaway kind cluster, installs it,
   and server-dry-run-applies fixtures — `tests/cel/reject/*.yaml` (6: public-empty
   allowlist, adopt-missing-vpc, vendrole-without-boundary, name-doubling,
   centralized-egress-no-tgw, ipam+literal-cidr) each must be denied with its
   `# EXPECT:` message; `tests/cel/accept/*.yaml` + `examples/*.yaml` each must be
   admitted. **Actually executed against a real kind cluster (k8s 1.35): 11/11
   passed.** Negative control run: with the endpoint rule stripped from the derived
   CRD, its reject fixture is admitted — so the harness fails on a real regression,
   not just malformed YAML. Wired as `task cel-test` + a `helm/kind-action@v1.14.0`
   CI job. `task validate` (yamllint + substrate contract + render) stays green.
