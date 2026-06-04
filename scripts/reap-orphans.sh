#!/usr/bin/env bash
#
# reap-orphans.sh — delete AWS resources stranded by a cluster vend/teardown that
# tofu can't reach (they're not in any tofu state).
#
# The factory tears clusters down via `Cluster` delete -> tofu destroy, which only
# removes resources in state. Two classes escape that and linger:
#   1. EKS control-plane log groups (/aws/eks/<cluster>/cluster) left by a teardown
#      that wasn't a clean tofu destroy (e.g. a hand-killed proof). A same-named
#      re-vend then fails with ResourceAlreadyExistsException.
#   2. Karpenter interruption infra (the Karpenter-<cluster> SQS queue + Karpenter*
#      EventBridge rules) orphaned when an apply created the AWS resource but errored
#      before tofu recorded it — e.g. the rule's PutRule succeeded but its TagResource
#      was denied, so the rule exists, is NOT in state, and is NOT tagged.
#
# Detection and the delete commands live in cloudgov, the org governance CLI that owns
# orphan reaping. `cloudgov orphans` flags dead-cluster residue (each candidate is
# matched against live `eks:ListClusters`, so a live cluster is never touched; a
# Karpenter rule with no ClusterName tag is failed-create debris), and
# `cloudgov remediate --type orphans` synthesizes the delete script. This wrapper
# scopes cloudgov's scan to the cluster-residue kinds and runs it for one
# profile/region.
#
# DRY-RUN by default (prints the delete script for review). Pass --apply to run it.
#
# Usage: reap-orphans.sh --profile <aws-profile> [--region us-west-2] [--apply]
# Requires: cloudgov (https://github.com/nanohype/cloudgov) and jq on PATH.

set -euo pipefail

PROFILE="" REGION="us-west-2" APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --apply)   APPLY=1;      shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "error: --profile is required" >&2; exit 2; }

CLOUDGOV="${CLOUDGOV:-$(command -v cloudgov || true)}"
[ -n "$CLOUDGOV" ] || {
  echo "error: cloudgov not found (set CLOUDGOV or install from github.com/nanohype/cloudgov)" >&2
  exit 2
}
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }

# cloudgov reads creds/region from the AWS SDK default chain.
export AWS_PROFILE="$PROFILE" AWS_REGION="$REGION"
mode=$([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)
echo "== reap-orphans [$mode] profile=$PROFILE region=$REGION =="

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Scan every orphan, then keep only cluster-teardown residue: cloudgov also surfaces
# unused disks/IPs/load balancers, but reaping here is intentionally scoped to the
# resources a cluster teardown leaves behind. (Go marshals an empty slice as null, so
# guard with // [].)
"$CLOUDGOV" orphans --output json --output-file "$workdir/orphans.json" --quiet
jq '{resources: [(.resources // [])[] |
      select(.Kind == "eks_log_group" or .Kind == "karpenter_queue" or .Kind == "karpenter_rule")]}' \
  "$workdir/orphans.json" > "$workdir/residue.json"

count=$(jq '.resources | length' "$workdir/residue.json")
if [ "$count" -eq 0 ]; then
  echo "== no cluster-teardown residue found =="
  exit 0
fi

# Synthesize the delete script(s) from the scoped residue.
"$CLOUDGOV" remediate --type orphans --from "$workdir/residue.json" --out "$workdir" --quiet
echo "-- $count orphaned resource(s) --"
for s in "$workdir"/delete-orphans-*.sh; do
  if [ "$APPLY" -eq 1 ]; then
    echo "== reaping ($(basename "$s")) =="
    bash "$s"
  else
    cat "$s"
  fi
done

echo "== $([ "$APPLY" -eq 1 ] && echo "reaped $count orphan(s)" || echo "found $count orphan(s) — re-run with APPLY=1 to delete") =="
