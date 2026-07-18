#!/usr/bin/env python3
"""Assert the composition <-> landing-zone substrate contract holds.

`crossplane render` never runs tofu, so nothing in CI otherwise catches the case
where the composition templates a Workspace var the pinned landing-zone commit
doesn't declare (undeclared var -> the vend fails ~immediately at `tofu plan`) or
fails to send a var the substrate requires (missing required var -> same failure).
Both are silent until a real vend. This gate closes that gap by diffing, at the
pinned SHA, the composition's templated var keys against each entrypoint's
`variables.tf`.

Checks:
  1. The `moduleSource` pin is identical in the XRD default and the composition
     (they must move in lockstep; the comments in both files say so).
  2. For each Workspace entrypoint (cluster-stack, cluster-bootstrap):
       a. every var the composition sends is declared by the pinned commit
          (no undeclared vars), and
       b. every required (no-default) substrate var is sent by the composition
          (no missing required vars).

The pinned `variables.tf` files are read from a local landing-zone checkout when
LANDING_ZONE_DIR points at one (dev-time, offline), otherwise fetched fresh from
GitHub at the pinned SHA (CI).

Exit non-zero on any violation, with a per-entrypoint diff.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "nanohype/landing-zone"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPOSITION = os.path.join(ROOT, "compositions", "cluster-aws.yaml")
DEFINITION = os.path.join(ROOT, "apis", "cluster", "definition.yaml")

# Workspace entrypoint -> path of its variables.tf in the landing-zone repo.
ENTRYPOINTS = {
    "fleet/aws/cluster-stack": "fleet/aws/cluster-stack/variables.tf",
    "fleet/aws/cluster-bootstrap": "fleet/aws/cluster-bootstrap/variables.tf",
}

PIN_RE = re.compile(r"landing-zone\.git\?ref=([0-9a-f]{7,40})")
VAR_KEY_RE = re.compile(r"-\s*\{key:\s*([a-z0-9_]+)\s*,")
ENTRYPOINT_RE = re.compile(r"^\s*entrypoint:\s*(\S+)\s*$")
HCL_VAR_RE = re.compile(r'^variable\s+"([a-z0-9_]+)"\s*\{')
HCL_DEFAULT_RE = re.compile(r"^\s*default\s*=")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def pins_in(text: str) -> list[str]:
    return PIN_RE.findall(text)


def resolve_pin() -> str:
    """The single, identical pin used by both the XRD default and the composition."""
    comp_pins = pins_in(read(COMPOSITION))
    def_pins = pins_in(read(DEFINITION))

    errs = []
    if len(comp_pins) != 1:
        errs.append(f"composition: expected exactly one moduleSource pin, found {comp_pins or 'none'}")
    if len(def_pins) != 1:
        errs.append(f"XRD default: expected exactly one moduleSource pin, found {def_pins or 'none'}")
    if errs:
        for e in errs:
            print(f"FAIL: {e}")
        sys.exit(1)

    if comp_pins[0] != def_pins[0]:
        print("FAIL: moduleSource pin is not in lockstep across the XRD and the composition")
        print(f"  apis/cluster/definition.yaml : {def_pins[0]}")
        print(f"  compositions/cluster-aws.yaml: {comp_pins[0]}")
        print("  Bump both to the same landing-zone SHA.")
        sys.exit(1)

    print(f"pin lockstep OK: both pinned to landing-zone {comp_pins[0]}")
    return comp_pins[0]


def composition_vars_by_entrypoint() -> dict[str, set[str]]:
    """Templated `- {key: X, ...}` var keys, grouped by the enclosing Workspace entrypoint."""
    current = None
    out: dict[str, set[str]] = {}
    for line in read(COMPOSITION).splitlines():
        m = ENTRYPOINT_RE.match(line)
        if m:
            current = m.group(1)
            out.setdefault(current, set())
            continue
        km = VAR_KEY_RE.search(line)
        if km and current is not None:
            out[current].add(km.group(1))
    return out


def fetch_variables_tf(sha: str, path: str) -> str:
    local = os.environ.get("LANDING_ZONE_DIR")
    if local:
        return subprocess.check_output(
            ["git", "-C", local, "show", f"{sha}:{path}"], text=True
        )

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    urls = []
    if token:
        urls.append(
            (
                f"https://api.github.com/repos/{REPO}/contents/{path}?ref={sha}",
                {
                    "Accept": "application/vnd.github.raw+json",
                    "Authorization": f"Bearer {token}",
                },
            )
        )
    urls.append((f"https://raw.githubusercontent.com/{REPO}/{sha}/{path}", {}))

    last = None
    for url, headers in urls:
        req = urllib.request.Request(
            url, headers={"User-Agent": "eks-fleet-substrate-contract", **headers}
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read().decode("utf-8")
        except urllib.error.URLError as exc:  # noqa: PERF203 - tiny fixed list
            last = exc
    raise SystemExit(f"FAIL: could not fetch {path} at {sha}: {last}")


def parse_hcl_variables(text: str) -> tuple[set[str], set[str]]:
    """(all declared var names, required var names = those with no `default`)."""
    declared: set[str] = set()
    required: set[str] = set()
    name = None
    has_default = False
    for line in text.splitlines():
        m = HCL_VAR_RE.match(line)
        if m:
            name = m.group(1)
            has_default = False
            declared.add(name)
            continue
        if name is None:
            continue
        if HCL_DEFAULT_RE.match(line):
            has_default = True
        elif line.startswith("}"):
            if not has_default:
                required.add(name)
            name = None
    return declared, required


def main() -> int:
    sha = resolve_pin()
    sent_by_entrypoint = composition_vars_by_entrypoint()

    failures = 0
    for entrypoint, var_path in ENTRYPOINTS.items():
        sent = sent_by_entrypoint.get(entrypoint)
        if sent is None:
            print(f"FAIL: composition declares no Workspace with entrypoint {entrypoint}")
            failures += 1
            continue

        declared, required = parse_hcl_variables(fetch_variables_tf(sha, var_path))

        undeclared = sorted(sent - declared)
        missing_required = sorted(required - sent)

        print(f"\n== {entrypoint} ==")
        print(f"  composition sends {len(sent)} vars; substrate declares {len(declared)} "
              f"({len(required)} required)")

        if undeclared:
            failures += 1
            print(f"  FAIL: composition sends vars the pinned commit does not declare: {undeclared}")
            print(f"        (these fail `tofu plan` with an undeclared-variable error)")
        if missing_required:
            failures += 1
            print(f"  FAIL: composition omits required substrate vars: {missing_required}")
            print(f"        (these fail `tofu plan` with a missing-required-variable error)")
        if not undeclared and not missing_required:
            print("  OK: every sent var is declared, every required var is sent")

    if failures:
        print(f"\nsubstrate contract check FAILED ({failures} violation(s))")
        return 1
    print("\nsubstrate contract check PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
