#!/usr/bin/env bash
#
# reap-orphans.sh — sweep AWS resources stranded by a cluster vend/teardown that
# tofu can't reach (they're not in any tofu state), then delete them.
#
# Why this exists: the factory tears clusters down via `Cluster` delete -> tofu
# destroy, which only removes resources in state. Two classes escape that:
#   1. EKS control-plane log groups (/aws/eks/<cluster>/cluster) left behind by a
#      teardown that wasn't a clean tofu destroy (e.g. a hand-killed proof). A
#      same-named re-vend then fails with ResourceAlreadyExistsException.
#   2. Karpenter interruption infra (SQS queue + EventBridge rules) orphaned when an
#      apply created the AWS resource but errored before tofu recorded it — e.g. the
#      rule's PutRule succeeded but its TagResource was denied, so the rule exists,
#      is NOT in state, and is NOT tagged. The next apply makes a fresh one.
#
# Every reapable resource is tied to a cluster name (in its name or a ClusterName
# tag); we only reap when that cluster is NOT in `aws eks list-clusters`. A failed
# Karpenter rule is identified by the Karpenter name prefix WITHOUT a ClusterName
# tag (a healthy rule from the module always carries it). Live clusters are never
# touched.
#
# DRY-RUN by default. Pass --apply to actually delete.
#
# Usage: reap-orphans.sh --profile <aws-profile> [--region us-west-2] [--apply]

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

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
mode=$([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)
echo "== reap-orphans [$mode] profile=$PROFILE region=$REGION =="

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
# space-padded live-cluster list for whole-word membership tests
LIVE=" $(aws eks list-clusters --query 'clusters[]' --output text | tr '\t' ' ') "
echo "live clusters:${LIVE}"
is_live() { case "$LIVE" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

REAPED=0 FOUND=0
act() { # act <describe-of-resource> <delete-cmd...>
  FOUND=$((FOUND + 1))
  echo "  ORPHAN: $1"
  if [ "$APPLY" -eq 1 ]; then shift; "$@" && REAPED=$((REAPED + 1)); fi
}

echo "-- EKS control-plane log groups (/aws/eks/<cluster>/cluster) --"
for lg in $(aws logs describe-log-groups --log-group-name-prefix /aws/eks \
              --query 'logGroups[].logGroupName' --output text | tr '\t' '\n'); do
  { [ -n "$lg" ] && [ "$lg" != "None" ]; } || continue
  cluster=$(printf '%s' "$lg" | sed -nE 's#^/aws/eks/(.+)/cluster$#\1#p')
  [ -n "$cluster" ] || continue
  is_live "$cluster" && continue
  act "log-group $lg (cluster '$cluster' not live)" \
      aws logs delete-log-group --log-group-name "$lg"
done

echo "-- Karpenter interruption SQS queues (Karpenter-<cluster>) --"
for q in $(aws sqs list-queues --queue-name-prefix Karpenter- \
             --query 'QueueUrls[]' --output text 2>/dev/null | tr '\t' '\n'); do
  { [ -n "$q" ] && [ "$q" != "None" ]; } || continue
  cluster=${q##*/Karpenter-}
  is_live "$cluster" && continue
  act "sqs $q (cluster '$cluster' not live)" \
      aws sqs delete-queue --queue-url "$q"
done

echo "-- Karpenter EventBridge rules (Karpenter*) --"
for r in $(aws events list-rules --name-prefix Karpenter \
             --query 'Rules[].Name' --output text | tr '\t' '\n'); do
  { [ -n "$r" ] && [ "$r" != "None" ]; } || continue
  # single-quoted on purpose: the backticks are JMESPath literals, not shell
  # shellcheck disable=SC2016
  cn=$(aws events list-tags-for-resource \
         --resource-arn "arn:aws:events:${REGION}:${ACCOUNT}:rule/${r}" \
         --query 'Tags[?Key==`ClusterName`].Value | [0]' --output text 2>/dev/null)
  if [ -n "$cn" ] && [ "$cn" != "None" ]; then
    is_live "$cn" && continue
    reason="cluster '$cn' not live"
  else
    reason="no ClusterName tag — failed-create debris"
  fi
  # a rule with targets can't be deleted until they're removed
  if [ "$APPLY" -eq 1 ]; then
    read -ra tids < <(aws events list-targets-by-rule --rule "$r" --query 'Targets[].Id' --output text 2>/dev/null | tr '\t' ' ')
    [ "${#tids[@]}" -gt 0 ] && aws events remove-targets --rule "$r" --ids "${tids[@]}" >/dev/null 2>&1 || true
  fi
  act "rule $r ($reason)" aws events delete-rule --name "$r"
done

echo "== $([ "$APPLY" -eq 1 ] && echo "reaped $REAPED of $FOUND" || echo "found $FOUND orphan(s) — re-run with --apply to delete") =="
