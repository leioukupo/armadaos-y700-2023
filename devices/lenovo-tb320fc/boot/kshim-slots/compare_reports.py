#!/usr/bin/env python3
"""Compare two build_android_boot.py reports so a packing change is judged by fields.

Usage:
    compare_reports.py <reference.report.json> <new.report.json> [--allow KEY ...]

Exit 0 when the layout and the AVB block agree (modulo --allow keys), else 1.
Reports are only comparable inside one slot: boot_a and boot_b have different
layouts by construction (A: shim_off=61669376 manifest_off=65863680
tail_off=65933312).

A --allow key is not a free pass: it still prints the value change. The usual case
is layout.packed_size moving by a few bytes because --base-name changed length -
the manifest name is not recorded in inputs, so nothing else in the report moves.
"""
import argparse
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def inner(doc, key, sub):
    """doc[key][sub] without exploding when key holds a plain string."""
    node = doc.get(key)
    if isinstance(node, dict):
        child = node.get(sub)
        if isinstance(child, dict):
            return child.get("path"), child.get("sha256")
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("new")
    ap.add_argument("--allow", nargs="*", default=[],
                    help="layout keys allowed to differ, e.g. packed_size when only"
                         " --base-name changed")
    args = ap.parse_args()

    ref, new = load(args.reference), load(args.new)
    ok = True

    rc, nc = len(ref.get("checks", [])), len(new.get("checks", []))
    fails = [c for c in new.get("checks", []) if not c.get("ok")]
    print(f"checks: reference={rc} new={nc} failed={len(fails)}")
    for c in fails:
        print(f"  CHECK_FAIL {c.get('check')}: {c.get('detail')}")
        ok = False

    la, lb = ref.get("layout", {}), new.get("layout", {})
    for key in sorted(set(la) | set(lb)):
        if la.get(key) != lb.get(key):
            tag = "allowed" if key in set(args.allow) else "DIFF"
            print(f"  {tag} layout.{key}: {la.get(key)!r} -> {lb.get(key)!r}")
            if tag == "DIFF":
                ok = False

    if ref.get("avb") != new.get("avb"):
        print("  DIFF avb block")
        ok = False

    for key in ("inputs",):
        rpath, rsha = inner(ref, key, "stock_boot")
        npath, nsha = inner(new, key, "stock_boot")
        if rsha and nsha and rsha != nsha:
            print(f"  DIFF {key}.stock_boot sha256: {rsha[:16]}... -> {nsha[:16]}..."
                  " (packing from a different backup; reports are not comparable)")
            ok = False
        rrt, _ = inner(ref, key, "runtime")
        nrt, _ = inner(new, key, "runtime")
        if rrt and nrt and rrt != nrt:
            print(f"  NOTE {key}.runtime changed: {rrt} -> {nrt}")

    if ok:
        print("REPORT_MATCH")
        return 0
    print("REPORT_MISMATCH (if only --base-name changed: re-run with --allow packed_size)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
