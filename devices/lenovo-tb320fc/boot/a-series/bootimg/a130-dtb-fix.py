#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# A130: repair strip_iommu_refs() in the shared boot-DTB generator a1/mk_a1_dtb.py.
#
 # A113 wrote that helper with a fixed 4-cell stride for iommu-map.  This board maps
# # with 5 cells (rid-base, phandle, #iommu-cells = 2 specifier cells, rid-length),
# # which is the layout drivers/of/base.c::of_map_id() and
# # qcom_pcie_config_sid_1_9_0() (drivers/pci/controller/dwc/pcie-qcom.c) walk.  On
# # the wrong stride the pcie0/pcie1 iommu-map reads as a reference to a SMMU that
# # is not kept, so strip_iommu_refs() deleted it from the boot DTB even with the
# # apps SMMU enabled - which is the entire WCN6855 failure.  Idempotent; keeps a
# # .pre-a130 copy of the file it edits.
import shutil
import sys

P = "/tmp/y700/a1/mk_a1_dtb.py"
s = open(P, encoding="utf-8").read()
if "def iommu_ref_phandles" in s:
    print("A130_DTB_FIX_ALREADY")
    sys.exit(0)


import re

HELPER_SRC = "/tmp/y700/a130_helpers.py"
helpers = open(HELPER_SRC, encoding="utf-8").read()

OLD_PARSE = """        # iommus = <phandle sid mask>...; iommu-map(-mask) = <rid phandle sid mask>...
        phs = vals[0::3] if hit == 'iommus' else vals[1::4]
"""
NEW_PARSE = """        # A113 cut a map property into 4-cell entries (rid, phandle, specifier,
        # mask).  The vendor stride on this board is 5; see iommu_ref_phandles().
        phs = iommu_ref_phandles(text, hit, vals)
"""
DEF = "def strip_iommu_refs(text, keep=None):"

for tag, old, new in (("parse", OLD_PARSE, NEW_PARSE), ("helpers", DEF, helpers + DEF)):
    if s.count(old) != 1:
        raise SystemExit("ANCHOR %s appears %d times" % (tag, s.count(old)))
    s = s.replace(old, new, 1)


shutil.copyfile(P, P + ".pre-a130")
with open(P, "w", encoding="utf-8", newline="\n") as f:
    f.write(s)

# self-test the inserted parser against the real property in base_a1.dts
ns = {"re": re}
seg = s[s.index("def iommu_cells_by_phandle"):s.index(DEF)]
exec(compile(seg, "a130-helpers", "exec"), ns)
base = open("/tmp/y700/a1/base_a1.dts", encoding="utf-8").read()
lines = [ln for ln in base.split("\n") if "iommu-map = <" in ln]
if len(lines) != 2:
    raise SystemExit("A130_SELFTEST base_a1.dts has %d iommu-map lines" % len(lines))
for ln in lines:
    vals = re.search(r"= <([^>]*)>;", ln).group(1).split()
    got = ns["iommu_ref_phandles"](base, "iommu-map", vals)
    if got != ["0x44", "0x44"]:
        raise SystemExit("A130_SELFTEST phandles=%s" % ",".join(got))
    print("selftest map ok: %s" % ln.strip())

import py_compile

py_compile.compile(P, doraise=True)
print("A130_DTB_FIX_OK")
