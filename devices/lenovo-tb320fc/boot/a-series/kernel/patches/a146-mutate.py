#!/usr/bin/env python3
# A146: derive the a146 round build script from a145, layering the power_now
# patch on top of the battmgr patch and tightening the gates so the module that
# rides into the image has to carry it.
import sys

SRC = "/tmp/y700/a145-build.sh"
DST = "/tmp/y700/a146-build.sh"

PATCH_BLOCK = '''# ---- A146: qcom_battmgr must derive power_now ----------------------------
# The SM8450 ADSP answers BATT_POWER_NOW about six times too high - 34.3 W for
# the 1.30 A discharge it reports itself at 4.22 V.  Plasma takes power_now as
# EnergyRate, so the desktop promised 25 minutes on a nearly full cell.
[ -s /tmp/y700/a146/patch.py ] || { echo A146_PATCHER_MISSING; exit 1; }
python3 /tmp/y700/a146/patch.py drivers/power/supply/qcom_battmgr.c || { echo A146_PATCH_FAIL; exit 1; }
grep -q "Y700-A146 battmgr derives" drivers/power/supply/qcom_battmgr.c || { echo A146_SRC_NOT_PATCHED; exit 1; }
echo "A146 battmgr source patched bytes=$(stat -c %s drivers/power/supply/qcom_battmgr.c)"
'''

KO_BLOCK = '''# ---- A146: the shipped battmgr module must derive the wattage ------------
grep -q "current_ua" drivers/power/supply/qcom_battmgr.c || { echo A146_SRC_PATCH_LOST; exit 1; }
strings "$IR/y700-ko/qcom_battmgr.ko" | grep -q "Y700-A146 battmgr derives" || { echo A146_KO_NOT_PATCHED; exit 1; }
echo "A146 battmgr ko staged size=$(stat -c %s "$IR/y700-ko/qcom_battmgr.ko") with the derived power_now"
'''

CPIO_BLOCK = '''# ---- A146: proof the derived power_now is inside the linked initramfs ----
strings usr/initramfs_data.cpio | grep -q "Y700-A146 battmgr derives" || { echo A146_NOT_IN_CPIO; exit 1; }
echo "A146 the cpio carries the wattage fix"
'''

A_ANCHOR = 'echo "A145 battmgr source patched bytes=$(stat -c %s drivers/power/supply/qcom_battmgr.c)"'
B_ANCHOR = 'echo "A145 battmgr ko staged size=$(stat -c %s "$IR/y700-ko/qcom_battmgr.ko") with the derived energy pair"'
C_ANCHOR = 'echo "A145 the cpio carries the patched battmgr"'


def once(src, old, new, tag):
    n = src.count(old)
    if n != 1:
        print("A146_MUTATE_ANCHOR tag=%s count=%d" % (tag, n))
        sys.exit(1)
    return src.replace(old, new, 1)


def main():
    src = open(SRC, encoding="utf-8", errors="surrogateescape").read()
    n = src.count("boot-b-a145")
    if n < 1:
        print("A146_MUTATE_NO_OUTPUT_NAME")
        return 1
    src = src.replace("boot-b-a145", "boot-b-a146")
    src = once(src, A_ANCHOR, A_ANCHOR + "\n" + PATCH_BLOCK, "patch")
    src = once(src, B_ANCHOR, B_ANCHOR + "\n" + KO_BLOCK, "ko")
    src = once(src, C_ANCHOR, C_ANCHOR + "\n" + CPIO_BLOCK, "cpio")
    if "boot-b-a145" in src:
        print("A146_MUTATE_LEFTOVER")
        return 1
    open(DST, "w", encoding="utf-8", errors="surrogateescape").write(src)
    print("A146_MUTATE_OK output_names=%d bytes=%d" % (src.count("boot-b-a146"), len(src)))
    return 0


if __name__ == "__main__":
    sys.exit(main())