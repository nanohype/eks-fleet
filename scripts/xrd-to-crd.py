#!/usr/bin/env python3
"""Derive a plain CustomResourceDefinition from the Cluster XRD.

`crossplane render` never evaluates the XRD's `x-kubernetes-validations` (CEL), so
nothing in CI otherwise proves the safety guardrails actually reject a bad spec.
The kube-apiserver *does* evaluate CEL — but only against a real CRD. When
Crossplane installs the XRD it generates exactly such a CRD, passing the
`openAPIV3Schema` (and every `x-kubernetes-validations` rule in it) through
verbatim. This script lifts that same `openAPIV3Schema` into a standalone CRD so a
plain kind cluster (no Crossplane install needed) enforces the identical rules —
the CEL under test is byte-identical to production because it is the same schema,
read from the same file at test time.

What the derived CRD leaves out is untested, and leaving something out is silent:
the CRD is merely smaller and the job still passes. So the script refuses a version
key it does not carry rather than dropping it.

Usage: xrd-to-crd.py <path-to-definition.yaml>   # writes the CRD YAML to stdout
"""

from __future__ import annotations

import sys

import yaml

# Version keys this script knows how to carry into the derived CRD. `referenceable`
# is XRD-only and maps to `storage`; the rest are CRD version fields of the same
# name. A key outside this set stops the run — see the check in main().
KNOWN_VERSION_KEYS = {
    "name",
    "served",
    "referenceable",
    "schema",
    "additionalPrinterColumns",
    "deprecated",
    "deprecationWarning",
}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: xrd-to-crd.py <definition.yaml>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as fh:
        xrd = yaml.safe_load(fh)

    if xrd.get("kind") != "CompositeResourceDefinition":
        print(f"FAIL: {sys.argv[1]} is not a CompositeResourceDefinition", file=sys.stderr)
        return 1

    spec = xrd["spec"]
    names = spec["names"]
    plural = names["plural"]
    kind = names["kind"]
    group = spec["group"]

    crd_versions = []
    for i, v in enumerate(spec["versions"]):
        # Refuse a version key this script does not carry, rather than dropping it.
        #
        # Everything the derived CRD omits is a thing the CEL job cannot test, and
        # omission is silent: the derived CRD is simply smaller, the job still
        # passes, and nothing says what was left behind. `additionalPrinterColumns`
        # was dropped this way, so a column with an invalid type or a malformed
        # jsonPath produced a byte-identical CRD and no gate ever saw it — while a
        # live hub rejects the XRD outright.
        #
        # Listing what to copy would have the same failure the next time the XRD
        # gains a field. Listing what is understood, and failing on the rest, moves
        # the default from silent-drop to loud-stop.
        unknown = sorted(set(v) - KNOWN_VERSION_KEYS)
        if unknown:
            print(
                f"FAIL: version {v['name']} declares {unknown}, which this script does "
                "not carry into the derived CRD.",
                file=sys.stderr,
            )
            print(
                "  Anything not carried is untested: add it below, or add it to "
                "KNOWN_VERSION_KEYS with a note saying why it cannot be.",
                file=sys.stderr,
            )
            return 1

        crd_version = {
            "name": v["name"],
            "served": v.get("served", True),
            # exactly one stored version; the XRD's `referenceable` flag maps to it
            "storage": v.get("referenceable", i == 0),
            "schema": {"openAPIV3Schema": v["schema"]["openAPIV3Schema"]},
        }
        # Carried so the API server validates them when the derived CRD is applied:
        # a column's type must be one it recognises and its jsonPath must parse.
        if "additionalPrinterColumns" in v:
            crd_version["additionalPrinterColumns"] = v["additionalPrinterColumns"]
        if "deprecated" in v:
            crd_version["deprecated"] = v["deprecated"]
            if "deprecationWarning" in v:
                crd_version["deprecationWarning"] = v["deprecationWarning"]
        crd_versions.append(crd_version)

    crd = {
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {"name": f"{plural}.{group}"},
        "spec": {
            "group": group,
            "scope": spec.get("scope", "Namespaced"),
            "names": {
                "kind": kind,
                "plural": plural,
                "singular": names.get("singular", kind.lower()),
            },
            "versions": crd_versions,
        },
    }

    yaml.safe_dump(crd, sys.stdout, default_flow_style=False, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
