#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# A130 = A128 (the last round that booted, served a desktop and took input) plus
# exactly one change: the boot device tree carries iommu-map on the PCIe hosts.
#
# Why this is the round.  strip_iommu_refs() in a1/mk_a1_dtb.py walked iommu-map
# with a 4-cell stride, but this board maps with 5 (rid-base, phandle, two
# #iommu-cells specifier cells, rid-length) - the stride of_map_id() in
# drivers/of/base.c and qcom_pcie_config_sid_1_9_0() in
# drivers/pci/controller/dwc/pcie-qcom.c both use.  So the vendor line for
# pcie@1c00000 read as three phandles (0x44, 0x100, 0x01), none of them the kept
# apps SMMU, and the property was deleted from every DTB since A96.  With no
# iommu-map, qcom_pcie_config_sid_1_9_0() returns 0 without programming
# PARF_BDF_TO_SID_CFG: the host leaves the BDF-to-SID table in bypass, the
# WCN6855 endpoint reaches the SMMU on a stream that owns no context bank, and
# the first host-memory DMA after ath11k has amss.bin is aborted.  That is one
# cause for the whole matrix: A122-A124 and A129 (firmware inside the initramfs,
# dead 3-5 s in), A121 and A128 (insmod once the root is up, dead on the spot),
# while A126 (ATH11K_PCI=y, no firmware in reach) stopped at -110 before any DMA
# and booted.  Nothing about the initcall window, KALLSYMS or the Image size
# was ever involved - A129 Image was 1 MB smaller than the A128 that boots.
#
# So A130 keeps A128 byte-for-byte everywhere else: ATH11K_PCI=m, the .ko in the
# initramfs, insmod after the root is mounted, the firmware staying in the root
# (a130-prep removes what A129 put into the initramfs again), and the config back
# at A128 (KALLSYMS_ALL on, gzip embedded cpio).  Late loading is now the better
# shape: DRAM does not survive these resets (RAMLOG and pstore both read empty),
# so the TF card mirror is the only post-mortem there is, and a probe after the
# card is mounted leaves a readable one.  The wifi script now logs the iommu
# group of the endpoint before insmod, which is the direct readout of this round.
# (See a130-dtb-fix.py for the parser repair and a130-dtb.sh for the DTB gates.)
import os

A = "/tmp/y700"
B = A + "/a1"


def rd(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def wr(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)


def one(t, old, new, what):
    n = t.count(old)
    if n != 1:
        raise SystemExit("ANCHOR %s appears %d times" % (what, n))
    return t.replace(old, new, 1)


# ---------------- 1. the initramfs patch ----------------
t = rd(A + "/a128/patch.sh").replace("A128", "A130").replace("a128", "a130")

LOAD = '\t\tL "load start ver=$(uname -r) ko=/usr/lib/y700/ath11k_pci.ko bin=$INSMOD"'
PRE = '\t\tL "pre grp=$(readlink /sys/bus/pci/devices/$DEV/iommu_group 2>/dev/null | sed s@.*/@@) drv=$(readlink /sys/bus/pci/devices/$DEV/driver 2>/dev/null | sed s@.*/@@)"'
t = one(t, LOAD, PRE + "\n" + LOAD, "wifi load start line")
wr(A + "/a130/patch.sh", t)
assert t.count("pre grp=$(readlink") == 1
assert "A130 KO installed" in t

# ---------------- 2. the init hook ----------------
ini = rd(A + "/a128/init-new").replace("A128", "A130").replace("a128", "a130")
wr(A + "/a130/init-new", ini)
assert "A130 PATCH_RUN" in ini

# ---------------- 3. prep ----------------
pr = rd(A + "/a128-prep.sh").replace("A128", "A130").replace("a128", "a130")

DTB_OLD = """# the DTB stays exactly the A115 bytes; this round must not move the platform
[ -s "$B/a1.dtb" ] || { echo NO_DTB; exit 1; }
cmp -s "$B/a1.dtb" "$B/a1.dtb.a115" || { echo A130_DTB_NOT_A115; sha256sum "$B/a1.dtb" "$B/a1.dtb.a115"; exit 1; }"""
DTB_NEW = """# ---- A130: the device tree moves on purpose: iommu-map on the PCIe hosts ----
bash /tmp/y700/a130-dtb.sh || { echo A130_DTB_STEP_FAIL; exit 1; }
sha256sum "$B/a1.dtb" "$B/a1.dtb.a130" """
pr = one(pr, DTB_OLD, DTB_NEW, "prep dtb pin")

CFG_OLD = "make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/y700/a130-olddef.log 2>&1 || { echo OLDDEFCONFIG_FAIL; tail -20 /tmp/y700/a130-olddef.log; exit 1; }"
CFG_NEW = """# A129 paid for the initramfs firmware with CONFIG_KALLSYMS_ALL and an XZ
 # embedded cpio.  A130 carries no firmware in the initramfs, so the config goes
 # back to exactly what A128 built with: the device tree is the only variable.
scripts/config --file .config -e KALLSYMS_ALL -e INITRAMFS_COMPRESSION_GZIP -d INITRAMFS_COMPRESSION_XZ
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/y700/a130-olddef.log 2>&1 || { echo OLDDEFCONFIG_FAIL; tail -20 /tmp/y700/a130-olddef.log; exit 1; }
grep -q '^CONFIG_KALLSYMS_ALL=y$' .config || { echo A130_KALLSYMS_ALL_OFF; exit 1; }
grep -q '^CONFIG_INITRAMFS_COMPRESSION_GZIP=y$' .config || { echo A130_NOT_GZIP; exit 1; }
grep -q '^# CONFIG_INITRAMFS_COMPRESSION_XZ is not set$' .config || { echo A130_STILL_XZ; exit 1; }"""
pr = one(pr, CFG_OLD, CFG_NEW, "prep olddefconfig")

FW_OLD = "if [ -d /tmp/y700/initramfs/lib/firmware/ath11k ] ; then echo A130_UNEXPECTED_ATH11K_FW; exit 1; fi"
FW_NEW = """# A129 baked the WCN6855 firmware into the initramfs directory; A130 loads the
 # driver from the root again, so the initramfs carries only the .ko.
rm -rf /tmp/y700/initramfs/lib/firmware/ath11k || { echo A130_FW_CLEAN_FAIL; exit 1; }
if [ -d /tmp/y700/initramfs/lib/firmware/ath11k ] ; then echo A130_UNEXPECTED_ATH11K_FW; exit 1; fi"""
pr = one(pr, FW_OLD, FW_NEW, "prep initramfs firmware")
wr(A + "/a130-prep.sh", pr)
assert "A130_PREP_OK" in pr

# ---------------- 4. build ----------------
b = rd(A + "/a128-build.sh").replace("A128", "A130").replace("a128", "a130")
b = one(b, "cmp -s \"$B/a1.dtb\" \"$B/a1.dtb.a115\" || { echo A130_DTB_NOT_A115; sha256sum \"$B/a1.dtb\" \"$B/a1.dtb.a115\"; exit 1; }",
        "cmp -s \"$B/a1.dtb\" \"$B/a1.dtb.a130\" || { echo A130_DTB_NOT_PINNED; sha256sum \"$B/a1.dtb\" \"$B/a1.dtb.a130\"; exit 1; }",
        "build dtb cmp")
b = one(b, "sha256sum \"$B/a1.dtb\" \"$B/a1.dtb.a115\"",
        "sha256sum \"$B/a1.dtb\" \"$B/a1.dtb.a130\" \"$B/a1.dtb.a115\"", "build dtb sha")
b = one(b, "python3 - \"$B/out/boot-b-a130.img\" \"$B/a1.dtb.a115\" <<'PYA114'",
        "python3 - \"$B/out/boot-b-a130.img\" \"$B/a1.dtb.a130\" <<'PYA130'", "image dtb argument")
if b.count("PYA114") != 1:
    raise SystemExit("A130 heredoc terminator moved: %d" % b.count("PYA114"))
b = b.replace("PYA114", "PYA130")
b = one(b, "print('a130 image %d bytes carries the a114 DTB (%d bytes) at %s'",
        "print('the a130 image (%d bytes) carries the pinned DTB (%d bytes) at %s'", "image dtb print")
b = one(b, "# ---- A130: the DTB has to be the A115 bytes (pcie0 unpinned), byte for byte ----",
        "# ---- A130: the DTB has to be the pinned a130 bytes, byte for byte ----",
        "build dtb comment")
b = one(b, "grep -q 'decision drvdir=' usr/initramfs_data.cpio || { echo A130_NO_DECISION_LINE; exit 1; }",
        "grep -q 'pre grp=$(readlink' usr/initramfs_data.cpio || { echo A130_NO_IOMMU_GROUP_PROBE; exit 1; }\ngrep -q 'decision drvdir=' usr/initramfs_data.cpio || { echo A130_NO_DECISION_LINE; exit 1; }",
        "pre grp gate")
b = one(b, "[ -s \"$IR/y700-ko/ath11k_pci.ko\" ] || { echo A130_KO_NOT_IN_TREE; exit 1; }",
        "[ -s \"$IR/y700-ko/ath11k_pci.ko\" ] || { echo A130_KO_NOT_IN_TREE; exit 1; }\nif [ -e \"$IR/lib/firmware/ath11k\" ] ; then echo A130_FW_BAKED_IN_INITRAMFS; exit 1; fi",
        "no-firmware-in-initramfs gate")
b = one(b, "echo \"A130 the module and the loader are inside the initramfs\"",
        "echo \"A130 the module is inside the initramfs and the firmware is not\"",
        "build module report")
wr(A + "/a130-build.sh", b)
assert b.count("a1.dtb.a130") >= 4, b.count("a1.dtb.a130")
assert b.count("a1.dtb.a115") == 1, b.count("a1.dtb.a115")
assert "A130_ALL_OK" in b
print("MK_A130_OK")
