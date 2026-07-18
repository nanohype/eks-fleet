# Network idiom — eks-fleet

Tactical plan for this repo's target in the network-idiom campaign. Master plan:
`~/.claude/plans/network-idiom.md`.

**Nothing is deployed today** — no live `Cluster` CR. Design for the cleanest shape;
no migration/backward-compat framing anywhere (greenfield doctrine). The one
forward-looking rule worth documenting in this target's own commit/comments: once a
`Cluster` CR *does* go live, a present-but-old-shape `network` field would get pruned
by Crossplane's structural schema and leave `create.vpcCidr` empty at the next
reconcile — so any future CR touching this field must be written in the nested shape
from day one. That's an operational note, not a blocker today.

## Status

| # | target | status |
|---|---|---|
| 5 | mirror discriminated network schema in Cluster XRD + composition; status subnet plumbing | ✅ |

Ends in a PR (never a direct push to `main`), CI green (poll `gh pr checks`
synchronously in the foreground — no backgrounded `--watch`), then squash-merge.

---

## Target 5 — mirror the discriminated network schema in the Cluster XRD + composition; status subnet plumbing (M)

**Depends on:** landing-zone Target 1 (substrate var names this template targets) and
Target 4 (bootstrap Workspace subnet vars) — both must be merged before starting.
Confirm the exact var names landing-zone's Target 1/4 PRs actually shipped
(`network_mode`, `ipam_pool_id`, `ipam_netmask_length`, `transit_gateway_id`,
`centralized_egress`, `adopt_vpc_id`, `adopt_private_subnet_ids`,
`adopt_public_subnet_ids`, `private_subnet_ids`) rather than assuming this plan's
names are final — read the merged landing-zone `variables.tf` files directly.

**Findings:** `apis/cluster/definition.yaml:151-161` has the flat
`network: {vpcCidr, maxAzs, natGateways}` with a whole-object default (lines
154-156 — the file's own comment explains why nested-only defaults don't apply when
the parent object is omitted entirely). `compositions/cluster-aws.yaml:89,101-102`
template `vpc_cidr`/`max_azs`/`nat_gateways` from `$net` onto the `cluster-stack`
Workspace; the status write-back (lines 199-210) has no subnet fields; the bootstrap
Workspace (lines 143-159) receives `vpc_id` from status but no subnets or mode. This
repo's own CLAUDE.md states the contract directly: "The Cluster API mirrors the
substrate... Don't fork the vocabulary" — kebab-case landing-zone vars map to
camelCase XRD fields 1:1.

**Approach:**
1. `apis/cluster/definition.yaml`: replace the flat `network` field with:
   ```
   network:
     mode: create | adopt   # default: create
     create:
       vpcCidr, ipamPoolId, ipamNetmaskLength, transitGatewayId, centralizedEgress,
       maxAzs, natGateways
     adopt:
       vpcId, subnetIds: { private: [], public: [] }
   ```
   Whole-object defaults at each level (mirror the existing pattern at lines
   154-156 and the `systemNodes` field's identical whole-object-default comment at
   lines 136-139 — a default on a nested field alone doesn't apply when the parent is
   omitted, which would leave patched vars empty and fail tofu's type coercion).
   Add `x-kubernetes-validations` (CEL): `adopt` mode requires non-empty
   `adopt.vpcId` + non-empty `adopt.subnetIds.private`;
   `create.centralizedEgress` requires non-empty `create.transitGatewayId`;
   `create.ipamPoolId` and a non-default `create.vpcCidr` are mutually exclusive
   (mirror landing-zone Target 1's own preconditions — same rules, same rejection
   points, just enforced at admission here instead of at `plan`).
   Add `status.privateSubnetIds`, `status.publicSubnetIds`, `status.subnetAzIds`
   (all `type: array, items: {type: string}`). **`subnetAzIds` must be populated
   from AZ IDs, not AZ names** (a second review pass flagged this: AZ *names* like
   `us-west-2a` map to different physical AZs per AWS account by design, so they
   aren't meaningful across the account boundary this status field is about to
   cross; AZ *IDs* like `usw2-az1` are the stable cross-account identifier — EKS's
   own shared-subnet docs call this out explicitly). landing-zone's Target 1-fix
   adds `private_subnet_az_ids`/`public_subnet_az_ids` outputs (via
   `availability_zone_id`, not the pre-existing name-based outputs) specifically for
   this — thread those into `subnetAzIds`, not the name-based ones.
2. `compositions/cluster-aws.yaml`: read `$net.create` / `$net.adopt` (whichever
   `mode` selects) and template `network_mode`, `vpc_cidr`, `ipam_pool_id`,
   `ipam_netmask_length`, `transit_gateway_id`, `centralized_egress`, `max_azs`,
   `nat_gateways` (create) or `adopt_vpc_id`, `adopt_private_subnet_ids`,
   `adopt_public_subnet_ids` (adopt, lists through `toJson | quote` — same pattern
   already used elsewhere in this composition for list-typed vars) onto the
   `cluster-stack` Workspace. Add the three new subnet fields to the status
   write-back. Pass `network_mode` + `private_subnet_ids` through to the bootstrap
   Workspace's vars (landing-zone Target 4 consumes them there).
3. `examples/`: rewrite every sample `Cluster` to the nested shape — keep (or add) a
   `create` example and an `adopt` example, both realistic (the adopt example
   references plausible-but-placeholder `vpc-`/`subnet-` IDs, never real ones).

**Acceptance:**
- `task validate` (yamllint + `crossplane render` each example against the
  compositions) green.
- The rendered `create` example's Workspace vars match landing-zone's actual merged
  Target 1 `cluster-stack/variables.tf` names exactly (verify by reading that file,
  not by assuming).
- The rendered `adopt` example shows `network_mode=adopt` plus the JSON-encoded
  adopt subnet-ID vars, and the status/bootstrap subnet plumbing is present in the
  rendered output.
- CEL validation rejects (at render/dry-run, or documented as admission-time-only if
  `crossplane render` doesn't evaluate CEL) `adopt` mode without `adopt.vpcId`, and
  `centralizedEgress: true` without `transitGatewayId`.

**Shipped.** `apis/cluster/definition.yaml`, `compositions/cluster-aws.yaml`,
`examples/`, and `docs/architecture.md` now carry the discriminated network schema.

- **Substrate var names verified against the merged landing-zone source** (not this
  plan's guesses). cluster-stack (`fleet/aws/cluster-stack/variables.tf`) accepts
  `network_mode`, `vpc_cidr`, `ipam_pool_id`, `ipam_netmask_length`,
  `transit_gateway_id`, `centralized_egress`, `max_azs`, `nat_gateways`,
  `adopt_vpc_id`, `adopt_private_subnet_ids`, `adopt_public_subnet_ids` — all mapped
  1:1. cluster-bootstrap (`fleet/aws/cluster-bootstrap/variables.tf`) accepts
  `network_mode`, `private_subnet_ids`, `public_subnet_ids` — the composition threads
  all three (both subnet lists, not just private: the scheme-aware LB injection needs
  public too). status write-back reads cluster-stack's `private_subnet_ids` /
  `public_subnet_ids` / `private_subnet_az_ids` outputs. All names matched what
  landing-zone actually shipped — no drift from the names carried into this target.
- **`subnetAzIds` ← `private_subnet_az_ids`** (AZ IDs like `usw2-az1`), not the
  name-based `private_subnet_azs` output — per the cross-account-stability note.
- **List handling is asymmetric by source, and it's load-bearing.** Vars sourced from
  spec/status (real YAML arrays → native slices in the templating context) go through
  `toJson | quote` (a quoted JSON string for the tofu `-var` flag): the adopt subnet
  vars on cluster-stack and the subnet vars on cluster-bootstrap. The status
  *write-back* fields (`privateSubnetIds`/`publicSubnetIds`/`subnetAzIds`) go through
  `toJson` **without** `quote` — provider-opentofu stores each tofu output as raw JSON
  (`json.Marshal(value)`), which function-go-templating decodes to a native slice, and
  the XRD status field is a typed array, so a bare `toJson` emits a real YAML array
  (confirmed against the provider source: `generateWorkspaceObservation` →
  `Output.JSONValue`; the existing scalar write-back's `| quote` only works because
  string outputs decode to native strings, which proves list outputs decode to native
  slices).
- **CEL is admission-time-only.** `crossplane render` (v2.4.0) does not evaluate
  `x-kubernetes-validations`, and — separately — its `--observed-resources` did not
  surface `.observed.resources` to the pipeline in this environment, so the two blocks
  gated on observed cluster-stack outputs (the status write-back and the bootstrap
  Workspace's `$csEndpoint` path) can't be exercised by a bare CI render. Verified
  instead: the create/adopt cluster-stack Workspaces and the bootstrap Workspace's
  network vars render correctly (the bootstrap block gates on the XR's *own* status,
  which a status-bearing XR populates), and the write-back block was force-rendered
  against a literal `$csOut` to confirm it emits real YAML arrays. The three CEL rules
  (adopt requires vpcId + private subnets; centralizedEgress requires transitGatewayId;
  ipamPoolId ⊥ non-default vpcCidr) mirror landing-zone network's own variable
  preconditions and fire at admission.
- **Forward-looking operational rule (documented, not a today-blocker):** once a
  `Cluster` CR goes live, a present-but-old-shape flat `network` field would be pruned
  by the structural schema and leave `create.vpcCidr` empty at the next reconcile — so
  any future CR touching this field must be written in the nested shape from day one.
