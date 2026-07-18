#!/usr/bin/env bash
# CEL admission tests for the Cluster XRD's x-kubernetes-validations.
#
# `crossplane render` never evaluates CEL, so nothing else in CI proves the XRD's
# safety guardrails actually reject a bad spec. This harness derives a plain CRD
# from apis/cluster/definition.yaml (scripts/xrd-to-crd.py lifts the exact
# openAPIV3Schema, so the rules under test are byte-identical to what Crossplane
# installs), stands it up on a throwaway kind cluster, and server-dry-run-applies
# a suite of fixtures:
#   - every tests/cel/reject/*.yaml must be DENIED at admission with the message
#     declared in its `# EXPECT:` header (grep-matched, so a denial for the wrong
#     reason still fails the test), and
#   - every tests/cel/accept/*.yaml and examples/*.yaml must be ADMITTED.
#
# Env:
#   CEL_TEST_CLUSTER  kind cluster name (default eks-fleet-cel; created if absent)
#   CEL_TEST_KEEP=1   keep the kind cluster after the run (default: delete it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CEL_TEST_CLUSTER:-eks-fleet-cel}"
NS=platform
CREATED_CLUSTER=0

KUBECTL() { kubectl --context "kind-${CLUSTER}" "$@"; }

cleanup() {
  if [ "$CREATED_CLUSTER" = "1" ] && [ "${CEL_TEST_KEEP:-}" != "1" ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "== creating throwaway kind cluster '$CLUSTER' =="
  kind create cluster --name "$CLUSTER" >/dev/null
  CREATED_CLUSTER=1
fi

echo "== installing the Cluster CRD derived from the XRD =="
python3 "$ROOT/scripts/xrd-to-crd.py" "$ROOT/apis/cluster/definition.yaml" | KUBECTL apply -f - >/dev/null
KUBECTL wait --for=condition=established crd/clusters.fleet.nanohype.dev --timeout=60s >/dev/null
KUBECTL create namespace "$NS" --dry-run=client -o yaml | KUBECTL apply -f - >/dev/null

pass=0
fail=0

echo
echo "== reject fixtures (must be DENIED at admission) =="
for f in "$ROOT"/tests/cel/reject/*.yaml; do
  name="$(basename "$f")"
  want="$(sed -n 's/^# EXPECT: //p' "$f" | head -1)"
  if [ -z "$want" ]; then
    echo "  ERROR $name: no '# EXPECT:' header"
    fail=$((fail + 1))
    continue
  fi
  out="$(KUBECTL apply --dry-run=server -f "$f" 2>&1 || true)"
  if printf '%s' "$out" | grep -qF -- "$want"; then
    echo "  PASS  $name -> denied: \"$want\""
    pass=$((pass + 1))
  else
    echo "  FAIL  $name: expected a denial containing \"$want\""
    echo "        got: $out"
    fail=$((fail + 1))
  fi
done

echo
echo "== accept fixtures (must be ADMITTED) =="
for f in "$ROOT"/tests/cel/accept/*.yaml "$ROOT"/examples/*.yaml; do
  name="$(basename "$f")"
  if out="$(KUBECTL apply --dry-run=server -f "$f" 2>&1)"; then
    echo "  PASS  $name -> admitted"
    pass=$((pass + 1))
  else
    echo "  FAIL  $name: expected admission, got denial:"
    echo "        $out"
    fail=$((fail + 1))
  fi
done

echo
echo "CEL admission tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
