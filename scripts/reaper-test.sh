#!/usr/bin/env bash
#
# reaper-test.sh — run the fleet-reaper CronJob's inline script against a stub
# kubectl.
#
# The reaper deletes real EKS clusters, and its failure mode is silence: a
# listing that errors must never read as "nothing expired". yamllint and
# `crossplane render` both see this script as an opaque string, so without this
# test the only shell in the repo that can destroy infrastructure is also the
# only thing nothing executes.
#
# The script runs verbatim out of config/reaper.yaml — extracted, never
# transcribed — so the test cannot pass while the shipped manifest regresses.
# jq and date are the real binaries, which puts the TTL filter and the date math
# under test alongside the control flow; only kubectl is stubbed, because the
# alternative is a live fleet.
#
# Usage: scripts/reaper-test.sh   (needs bash, jq, python3 + pyyaml)

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/config/reaper.yaml"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# ─── extract the shipped script ───
#
# Pulled out of the CronJob rather than kept as a copy here: a copy would keep
# passing while the manifest drifted, which is the class of failure this whole
# file exists to catch.
python3 - "$manifest" > "$workdir/reaper.sh" <<'PY'
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cronjobs = [d for d in docs if d.get("kind") == "CronJob"]
if len(cronjobs) != 1:
    sys.exit(f"expected exactly 1 CronJob in the manifest, found {len(cronjobs)}")

containers = cronjobs[0]["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"]
if len(containers) != 1:
    sys.exit(f"expected exactly 1 container, found {len(containers)}")

command = containers[0]["command"]
if command[:2] != ["/bin/sh", "-c"]:
    sys.exit(f"expected a `/bin/sh -c` command, found {command[:2]!r}")

sys.stdout.write(command[2])
PY

# ─── stub kubectl ───
mkdir -p "$workdir/bin"
cat > "$workdir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# `get` serves a fixture or fails on demand; `delete` is recorded and never run.
case "${1:-}" in
  get)
    if [ "${STUB_GET_FAILS:-0}" = "1" ]; then
      echo 'Error from server (Forbidden): clusters.fleet.nanohype.dev is forbidden' >&2
      exit 1
    fi
    cat "$STUB_GET_JSON"
    ;;
  delete)
    shift
    printf '%s\n' "$*" >> "$STUB_DELETE_LOG"
    ;;
  *)
    echo "stub kubectl: unexpected verb '${1:-}'" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$workdir/bin/kubectl"

delete_log="$workdir/deletes.log"
export STUB_DELETE_LOG="$delete_log"

# ─── fixtures ───
#
# `-` as ttlDays omits the field entirely — that is how a persistent cluster is
# expressed, and it must never become a candidate.
#
# The two timestamps are absolute rather than computed from `now` so a reader can
# see at a glance which side of the TTL each case lands on.
EXPIRED_AT="2020-01-01T00:00:00Z" # + 1 day is long past
LIVE_AT="2099-01-01T00:00:00Z"    # + 1 day is far in the future

items() {
  local out="" sep="" ns name ttl created spec
  while [ $# -gt 0 ]; do
    ns=$1 name=$2 ttl=$3 created=$4
    shift 4
    spec='{}'
    [ "$ttl" = "-" ] || spec=$(printf '{"ttlDays":%s}' "$ttl")
    out=$(printf '%s%s{"metadata":{"namespace":"%s","name":"%s","creationTimestamp":"%s"},"spec":%s}' \
      "$out" "$sep" "$ns" "$name" "$created" "$spec")
    sep=,
  done
  printf '{"items":[%s]}' "$out"
}

# ─── assertions ───
failures=0

expect() { # <name> <want_exit> <want_delete_count> <want_output_substring>
  local name=$1 want_exit=$2 want_deletes=$3 want_substring=$4
  local got_exit=0 out got_deletes bad=0

  : > "$delete_log"
  out=$(PATH="$workdir/bin:$PATH" /bin/sh "$workdir/reaper.sh" 2>&1) || got_exit=$?
  got_deletes=$(grep -c . "$delete_log" || true)

  [ "$got_exit" -eq "$want_exit" ] ||
    { bad=1; printf '       exit status: want %s, got %s\n' "$want_exit" "$got_exit"; }
  [ "$got_deletes" -eq "$want_deletes" ] ||
    { bad=1; printf '       deletes: want %s, got %s\n' "$want_deletes" "$got_deletes"; }
  case "$out" in
    *"$want_substring"*) ;;
    *) bad=1; printf '       output: want it to contain %s\n' "$want_substring" ;;
  esac

  if [ "$bad" -eq 0 ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/       | /'
    failures=$((failures + 1))
  fi
}

# The load-bearing case. A pipeline's status is the last command's and jq exits 0
# on empty stdin, so `kubectl ... | jq` prints "no expired ephemeral clusters" and
# exits 0 on RBAC drift, an API error or a missing CRD — green while every ephemeral
# spoke leaks. This asserts the failure propagates instead.
export STUB_GET_FAILS=1 STUB_GET_JSON=/dev/null DRY_RUN=false MAX_REAP=5
expect "a failed listing fails the job" 1 0 "Forbidden"

unset STUB_GET_FAILS

items > "$workdir/empty.json"
STUB_GET_JSON="$workdir/empty.json" \
  expect "an empty fleet reaps nothing" 0 0 "no expired ephemeral clusters"

# Persistent clusters are the ones a mistake here would destroy irrecoverably,
# so both spellings are pinned: no ttlDays at all, and an explicit 0.
items team-a keeper-no-ttl - "$EXPIRED_AT" \
      team-a keeper-zero-ttl 0 "$EXPIRED_AT" > "$workdir/persistent.json"
STUB_GET_JSON="$workdir/persistent.json" \
  expect "persistent clusters are never candidates" 0 0 "no expired ephemeral clusters"

items team-a expired-1 1 "$EXPIRED_AT" \
      team-b live-1 1 "$LIVE_AT" > "$workdir/mixed.json"

STUB_GET_JSON="$workdir/mixed.json" DRY_RUN=true \
  expect "DRY_RUN reports without deleting" 0 0 "DRY-RUN"

STUB_GET_JSON="$workdir/mixed.json" DRY_RUN=false \
  expect "an armed reap deletes the expired cluster" 0 1 "reaping expired cluster team-a/expired-1"

# The delete count above proves one cluster died; this proves it was the right
# one. A filter inversion would satisfy the count and destroy the live cluster.
if grep -q 'team-a expired-1' "$delete_log"; then
  printf 'ok   the delete targets the expired cluster, not the live one\n'
else
  printf 'FAIL the delete targets the expired cluster, not the live one\n'
  printf '       delete log: %s\n' "$(cat "$delete_log")"
  failures=$((failures + 1))
fi

set -- team-a e1 1 "$EXPIRED_AT" team-a e2 1 "$EXPIRED_AT" team-a e3 1 "$EXPIRED_AT" \
       team-a e4 1 "$EXPIRED_AT" team-a e5 1 "$EXPIRED_AT" team-a e6 1 "$EXPIRED_AT"
items "$@" > "$workdir/mass.json"
STUB_GET_JSON="$workdir/mass.json" DRY_RUN=false MAX_REAP=5 \
  expect "MAX_REAP refuses a mass reap" 1 0 "refusing to reap"

if [ "$failures" -ne 0 ]; then
  printf '\n%s reaper check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall reaper checks passed\n'
