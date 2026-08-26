#!/usr/bin/env bash
# Mutation tests for scripts/check-substrate-contract.py.
#
# The contract gate's value is entirely in what it can SEE. It reads the
# composition's Workspace vars and diffs them against the pinned substrate, so a
# var it fails to notice is a var it reports as correct — the same green as a
# clean tree, with no evidence that anything was skipped.
#
# A gate like that cannot be validated by running it on a correct tree, because a
# correct tree is what a blind gate also reports. Each case below breaks the
# contract in one legal spelling and asserts the gate says so. Together they pin
# the gate's scope: the spellings here are the ones it is claimed to cover, and a
# change that narrows it fails.
#
# Usage: scripts/substrate-contract-test.sh   (needs python3 + pyyaml; network or
#        LANDING_ZONE_DIR, same as the gate itself)

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

failures=0

# Each case mutates a copy of the composition, then asserts the gate's verdict.
# `want` is `fail` for a broken contract and `pass` for the untouched tree.
check() { # <want> <name> <python-mutation>
  local want=$1 name=$2 mutation=$3 rc=0

  rm -rf "$workdir/t"
  mkdir -p "$workdir/t/scripts" "$workdir/t/compositions" "$workdir/t/apis/cluster"
  cp "$root/scripts/check-substrate-contract.py" "$workdir/t/scripts/"
  cp "$root/compositions/cluster-aws.yaml" "$workdir/t/compositions/"
  cp "$root/apis/cluster/definition.yaml" "$workdir/t/apis/cluster/"
  python3 -c "$mutation" "$workdir/t/compositions/cluster-aws.yaml"

  local out
  out=$(python3 "$workdir/t/scripts/check-substrate-contract.py" 2>&1) || rc=$?

  if { [ "$want" = fail ] && [ "$rc" -ne 0 ]; } || { [ "$want" = pass ] && [ "$rc" -eq 0 ]; }; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s (want %s, got exit %s)\n' "$name" "$want" "$rc"
    printf '%s\n' "$out" | sed 's/^/       | /'
    failures=$((failures + 1))
  fi
}

# Insert a line after the first vars entry matching a marker.
after() { # <marker> <lines...>
  printf 'import sys\nL=open(sys.argv[1]).read().splitlines(True)\ni=[n for n,l in enumerate(L) if %s in l][0]\nL[i]+=%s\nopen(sys.argv[1],"w").writelines(L)\n' "$1" "$2"
}

# ─── undeclared vars, in each spelling YAML allows ───
#
# All three are the same mapping to a YAML parser and the same var to tofu. Any
# of them names a variable the pinned substrate does not declare, which fails
# `tofu plan` on every vend.
check fail "an undeclared var in block form is caught" \
  "$(after '"key: ttl_days"' '"                  - key: undeclared_block\n                    value: \"x\"\n"')"

check fail "an undeclared var with the keys reordered is caught" \
  "$(after '"key: ttl_days"' '"                  - {value: \"x\", key: undeclared_reordered}\n"')"

check fail "an undeclared var with a quoted key is caught" \
  "$(after '"key: ttl_days"' '"                  - {\"key\": \"undeclared_quoted\", \"value\": \"x\"}\n"')"

# ─── a required var that is not really sent ───
#
# A commented-out var is absent from the render. Reading the file as text counts
# it as present, which turns a vend-breaking omission into a green run.
check fail "a commented-out required var is not counted as sent" \
  'import sys
L=open(sys.argv[1]).read().splitlines(True)
i=[n for n,l in enumerate(L) if "key: region" in l][0]
L[i]="                  # "+L[i].lstrip()
open(sys.argv[1],"w").writelines(L)'

# A var inside a conditional is absent from every render that skips the branch,
# so a required var may not be sent that way.
#
# shellcheck disable=SC2016  # `$spec.region` is go-template source, not shell
check fail "a required var sent only under a conditional is caught" \
  'import sys
L=open(sys.argv[1]).read().splitlines(True)
i=[n for n,l in enumerate(L) if "key: region" in l][0]
L[i]="                  {{- if $spec.region }}\n"+L[i]+"                  {{- end }}\n"
open(sys.argv[1],"w").writelines(L)'

# ─── the control ───
#
# Without this, every assertion above is satisfied by a gate that always fails.
check pass "the untouched composition passes" 'import sys'

if [ "$failures" -ne 0 ]; then
  printf '\n%s substrate-contract check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall substrate-contract mutation checks passed\n'
