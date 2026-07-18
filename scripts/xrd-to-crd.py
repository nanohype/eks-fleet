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

Usage: xrd-to-crd.py <path-to-definition.yaml>   # writes the CRD YAML to stdout
"""

from __future__ import annotations

import sys

import yaml


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
        crd_versions.append(
            {
                "name": v["name"],
                "served": v.get("served", True),
                # exactly one stored version; the XRD's `referenceable` flag maps to it
                "storage": v.get("referenceable", i == 0),
                "schema": {"openAPIV3Schema": v["schema"]["openAPIV3Schema"]},
            }
        )

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
