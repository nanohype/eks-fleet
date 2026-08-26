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
          (no missing required vars), and
       c. no required substrate var is sent only under a conditional, which is a
          missing var for whichever specs skip the branch.

The composition is read by parsing it. Its Workspace vars are YAML, and YAML gives
the same mapping several spellings — a flow mapping, a block mapping, the keys in
either order, a quoted key — while a comment gives something that looks like a var
and is not one. Matching text finds the spelling its author had in mind; the vars it
misses are reported as correct, because this gate compares sets and an unseen var is
absent from both sides. `scripts/substrate-contract-test.sh` pins that scope.

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

import yaml

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
VAR_KEY_SHAPE = re.compile(r"^[a-z0-9_]+$")
HCL_VAR_RE = re.compile(r'^variable\s+"([a-z0-9_]+)"\s*\{')
HCL_DEFAULT_RE = re.compile(r"^\s*default\s*=")

# A whole-line go-template action — `{{- if $x }}`, `{{- end }}`, a `{{/* … */}}`
# comment. These carry no YAML, so they are dropped before parsing.
TMPL_LINE_RE = re.compile(r"^\s*\{\{.*\}\}\s*$")
# An inline action standing in for a scalar: `value: {{ $spec.region | quote }}`.
TMPL_INLINE_RE = re.compile(r"\{\{.*?\}\}")
# The actions that open and close a conditional block.
TMPL_OPEN_RE = re.compile(r"\{\{-?\s*(if|range|with)\b")
TMPL_CLOSE_RE = re.compile(r"\{\{-?\s*end\s*-?\}\}")
MARK_RE = re.compile("\x00(OPEN|CLOSE|A)\x00")


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


def template_of(path: str) -> str:
    """The go-templating step's inline template, read out of the Composition."""
    comp = yaml.safe_load(read(path))
    for step in comp["spec"]["pipeline"]:
        inline = step.get("input", {}).get("inline")
        if inline and "template" in inline:
            return inline["template"]
    raise SystemExit("FAIL: the composition declares no inline go-template step")


def yamlish(template: str) -> tuple[str, list[int]]:
    """The template as parseable YAML, plus the conditional depth of each line.

    Every `{{ … }}` is a hole in the YAML, so the document cannot be loaded as it
    stands. Actions collapse to a marker first — they can span lines, as the
    `{{- /* … */}}` comment blocks here do — then a line made only of markers is
    dropped and any remaining marker becomes a placeholder scalar. What is left has
    the same structure and the same keys as the rendered output.

    Parsing that is what lets this gate see a var however it is spelled: a flow
    mapping, a block mapping, the keys in either order, a quoted key. A pattern sees
    only the spelling its author had in mind, and a var this gate cannot see is a
    var it counts as correct.
    """
    def mark(m: re.Match[str]) -> str:
        body = m.group(0)
        if TMPL_OPEN_RE.search(body):
            return "\x00OPEN\x00"
        if TMPL_CLOSE_RE.search(body):
            return "\x00CLOSE\x00"
        return "\x00A\x00"

    collapsed = re.sub(r"\{\{.*?\}\}", mark, template, flags=re.S)

    out: list[str] = []
    depths: list[int] = []
    depth = 0
    for line in collapsed.splitlines():
        marks = MARK_RE.findall(line)
        if marks and not MARK_RE.sub("", line).strip():
            depth = max(depth + marks.count("OPEN") - marks.count("CLOSE"), 0)
            continue
        depths.append(depth)
        out.append(MARK_RE.sub("_", line))
    return "\n".join(out), depths


def composition_vars_by_entrypoint() -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """(vars sent per entrypoint, and of those the ones sent only under a conditional).

    A var is conditional when it sits deeper than the Workspace that carries it, so
    a Workspace that is itself gated (cluster-bootstrap waits on the cluster's
    endpoint) does not make all of its vars look optional.
    """
    text, depths = yamlish(template_of(COMPOSITION))

    sent: dict[str, set[str]] = {}
    gated: dict[str, set[str]] = {}
    for node in yaml.compose_all(text):
        doc = yaml.safe_load(yaml.serialize(node))
        if not isinstance(doc, dict) or doc.get("kind") != "Workspace":
            continue
        fp = doc.get("spec", {}).get("forProvider", {}) or {}
        entrypoint = fp.get("entrypoint")
        if not entrypoint:
            continue
        base = depths[node.start_mark.line]
        keys = sent.setdefault(entrypoint, set())
        gate = gated.setdefault(entrypoint, set())

        for key_node, line in var_key_nodes(node):
            key = key_node.value
            if not VAR_KEY_SHAPE.match(key):
                print(f"FAIL: {entrypoint}: {key!r} is not a valid tofu identifier")
                print("  A tofu variable name is [a-z0-9_]+. A key outside that is")
                print("  undeclared by any substrate, so the vend fails at plan.")
                sys.exit(1)
            keys.add(key)
            if depths[line] > base:
                gate.add(key)

    if not sent:
        print("FAIL: the composition renders no Workspace declaring an entrypoint")
        sys.exit(1)
    return sent, gated


def var_key_nodes(workspace: yaml.Node):
    """Every `vars[].key` scalar node of a Workspace, with the line it sits on."""
    def get(mapping, name):
        for k, v in mapping.value:
            if k.value == name:
                return v
        return None

    fp = get(get(workspace, "spec"), "forProvider")
    vars_node = get(fp, "vars") if fp is not None else None
    if vars_node is None:
        return
    for item in vars_node.value:
        key = get(item, "key")
        if key is None:
            print(f"FAIL: a Workspace vars entry has no `key` (line {item.start_mark.line + 1})")
            sys.exit(1)
        yield key, key.start_mark.line


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
    sent_by_entrypoint, gated_by_entrypoint = composition_vars_by_entrypoint()

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
        # A var the substrate requires must be sent on every render, so a required
        # var inside a conditional is a missing var for whichever specs skip the
        # branch — indistinguishable from a green run until a real vend takes it.
        gated_required = sorted(required & gated_by_entrypoint.get(entrypoint, set()))

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
        if gated_required:
            failures += 1
            print(f"  FAIL: required substrate vars sent only under a conditional: {gated_required}")
            print(f"        (a spec that skips the branch fails `tofu plan` with a missing-required-variable error)")
        if not undeclared and not missing_required and not gated_required:
            print("  OK: every sent var is declared, every required var is sent")

    if failures:
        print(f"\nsubstrate contract check FAILED ({failures} violation(s))")
        return 1
    print("\nsubstrate contract check PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
