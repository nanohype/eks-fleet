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
#   - every tests/cel/accept/*.yaml and examples/*.yaml must be ADMITTED, and
#   - each immutable spec field must be DENIED when changed on a Cluster that
#     already exists, which is the one class the dry-run loops cannot reach: they
#     only ever create, so `oldSelf` never exists and a transition rule is skipped.
#
# The derived CRD is also applied twice. A fresh cluster only exercises the create
# path, and the API server decodes an update strictly where it tolerates a create.
#
# Env:
#   CEL_TEST_CLUSTER  kind cluster name (default eks-fleet-cel; created if absent)
#   CEL_TEST_KEEP=1   keep the kind cluster after the run (default: delete it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CEL_TEST_CLUSTER:-eks-fleet-cel}"
NS=platform
CREATED_CLUSTER=0
CRD="$(mktemp)"

KUBECTL() { kubectl --context "kind-${CLUSTER}" "$@"; }

cleanup() {
  rm -f "$CRD"
  if [ "$CREATED_CLUSTER" = "1" ] && [ "${CEL_TEST_KEEP:-}" != "1" ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Assert each fixture set is non-empty before testing it. A suite that iterates an
# unmatched glob reports on nothing: "every reject fixture was denied" and "every
# accept fixture was admitted" are both trivially true of an empty set, and the
# tally reaches `[ "$fail" -eq 0 ]` as 0 passed, 0 failed. What stands between this
# suite and that outcome is only that `sed` and `kubectl` happen to error on a
# missing path — an error, not an assertion. Count first, and print the counts, so
# a run that examined nothing cannot look like a run that examined everything.
count_fixtures() { # <label> <dir>
  set -- "$1" "$2"
  # Enumerate with the same glob the loops below use, not an equivalent-looking one.
  # `find -name '*.yaml'` matches dotfiles and `*.yaml` does not, so the two disagree
  # on the population and the printed count stops describing what was tested. A guard
  # is only worth its line if it counts the set the loop iterates.
  n=0
  for _f in "$2"/*.yaml; do
    [ -e "$_f" ] || continue   # unmatched glob expands to the literal pattern
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    echo "ERROR: no $1 fixtures found in $2 — the suite would report on an empty set" >&2
    exit 1
  fi
  echo "  $1: $n"
}

echo "== fixture inventory =="
count_fixtures "reject" "$ROOT/tests/cel/reject"
count_fixtures "accept" "$ROOT/tests/cel/accept"
count_fixtures "examples" "$ROOT/examples"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "== creating throwaway kind cluster '$CLUSTER' =="
  kind create cluster --name "$CLUSTER" >/dev/null
  CREATED_CLUSTER=1
fi

echo "== installing the Cluster CRD derived from the XRD =="
python3 "$ROOT/scripts/xrd-to-crd.py" "$ROOT/apis/cluster/definition.yaml" > "$CRD"
KUBECTL apply -f "$CRD" >/dev/null
KUBECTL wait --for=condition=established crd/clusters.fleet.nanohype.dev --timeout=60s >/dev/null

# Apply it a SECOND time. Installing onto a fresh cluster only exercises the create
# path, and the API server decodes an update strictly where it tolerates a create —
# so a schema defect can pass a first install and then fail every sync after it on a
# live hub, which is how a malformed field description once shipped. A re-apply must
# report `configured` or `unchanged`; anything else means the shipped XRD is not
# re-appliable, and a hub reconciles by re-applying.
echo "== re-applying the same CRD (the path a live hub takes on every sync) =="
if out="$(KUBECTL apply -f "$CRD" 2>&1)"; then
  case "$out" in
    *configured | *unchanged) echo "  PASS  re-apply -> ${out##* }" ;;
    *) echo "  FAIL  re-apply reported neither configured nor unchanged: $out" ; exit 1 ;;
  esac
else
  echo "  FAIL  the derived CRD is not re-appliable: $out"
  exit 1
fi
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

# ─── transition rules (must be DENIED on UPDATE) ───
#
# A transition rule is the one kind the loops above cannot reach. They
# server-dry-run each fixture against an empty cluster, so every apply is a create
# and `oldSelf` never exists — the rule is skipped, and a suite that only creates
# reports green whether the rule works or is absent entirely.
#
# So this creates one Cluster for real, then re-applies it with a single field
# changed. The unchanged re-apply is asserted too, which is what separates "the rule
# rejects an edit" from "the rule rejects everything".
echo
echo "== transition rules (must be DENIED on UPDATE) =="
BASE="$ROOT/tests/cel/accept/minimal-required-only.yaml"
KUBECTL apply -f "$BASE" >/dev/null

if KUBECTL apply --dry-run=server -f "$BASE" >/dev/null 2>&1; then
  echo "  PASS  re-applying the base unchanged is still admitted"
  pass=$((pass + 1))
else
  echo "  FAIL  re-applying the base unchanged was denied — a transition rule is too broad"
  fail=$((fail + 1))
fi

mutate() { # <field> <value>  -> the base fixture with one spec field changed
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); d["spec"][sys.argv[2]]=sys.argv[3]; print(yaml.safe_dump(d,sort_keys=False))' \
    "$BASE" "$1" "$2"
}

while read -r field value; do
  [ -n "$field" ] || continue
  out="$(mutate "$field" "$value" | KUBECTL apply --dry-run=server -f - 2>&1 || true)"
  if printf '%s' "$out" | grep -qF -- "spec.$field is immutable"; then
    echo "  PASS  changing spec.$field on a live Cluster is denied"
    pass=$((pass + 1))
  else
    echo "  FAIL  changing spec.$field was not denied as immutable"
    echo "        got: $out"
    fail=$((fail + 1))
  fi
done <<'FIELDS'
region eu-west-1
clusterName renamed
stateBucket some-other-bucket
stateRegion eu-west-1
FIELDS

echo
echo "CEL admission tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
