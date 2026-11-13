#!/usr/bin/env python3
# A145: derive the a145 round build script from a143, adding the battmgr patch
# step plus the gates that prove the patched module rode into the image.
import sys

SRC = "/tmp/y700/a143-build.sh"
DST = "/tmp/y700/a145-build.sh"

PATCH_BLOCK = '''# ---- A145: qcom_battmgr must answer the charge/energy pair --------------
# SM8450 firmware never fills power_unit, so upstream hides CHARGE_*/ENERGY_*
# as -ENODATA.  KDE works out the level as Energy/EnergyFull, so with no
# energy pair it thinks the cell is empty and pops "battery very low, sleeping
# in 60 s" whenever it re-checks, e.g. after a DPMS blank.  Derive the pair
# from the coulomb counter instead.
[ -s /tmp/y700/a145/patch.py ] || { echo A145_PATCHER_MISSING; exit 1; }
if [ ! -s /tmp/y700/a145/qcom_battmgr.c.a145pre ]; then
	cp -f drivers/power/supply/qcom_battmgr.c /tmp/y700/a145/qcom_battmgr.c.a145pre || exit 1
	echo A145_PRE_SAVED
fi
cp -f /tmp/y700/a145/qcom_battmgr.c.a145pre drivers/power/supply/qcom_battmgr.c || exit 1
python3 /tmp/y700/a145/patch.py drivers/power/supply/qcom_battmgr.c || { echo A145_PATCH_FAIL; exit 1; }
grep -q "Y700-A145 battmgr derives" drivers/power/supply/qcom_battmgr.c || { echo A145_SRC_NOT_PATCHED; exit 1; }
echo "A145 battmgr source patched bytes=$(stat -c %s drivers/power/supply/qcom_battmgr.c)"
'''

KO_BLOCK = '''# ---- A145: the shipped battmgr module must be the patched one ----------
grep -q "sm8350_bat_is_derived(psp)" drivers/power/supply/qcom_battmgr.c || { echo A145_SRC_PATCH_LOST; exit 1; }
strings "$IR/y700-ko/qcom_battmgr.ko" | grep -q "Y700-A145 battmgr derives" || { echo A145_KO_NOT_PATCHED; exit 1; }
echo "A145 battmgr ko staged size=$(stat -c %s "$IR/y700-ko/qcom_battmgr.ko") with the derived energy pair"
'''

CPIO_BLOCK = '''# ---- A145: proof the patched module is inside the linked initramfs ------
strings usr/initramfs_data.cpio | grep -q "Y700-A145 battmgr derives" || { echo A145_NOT_IN_CPIO; exit 1; }
echo "A145 the cpio carries the patched battmgr"
'''

A_ANCHOR = 'make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j${JOBS:-24} modules > /tmp/y700/kbuild/a131-modules.log 2>&1 || { echo A131_MODULES_FAIL; tail -40 /tmp/y700/kbuild/a131-modules.log; exit 1; }'
B_ANCHOR = 'sha256sum "$IR"/y700-ko/*.ko | head -20'
C_ANCHOR = 'for n in y700-patch.sh y700-audio.sh A131 APPLIED a730_sqe.fw gmu_gen70000.bin a730_zap.mdt; do'


def once(src, old, new, tag):
    n = src.count(old)
    if n != 1:
        print("A145_MUTATE_ANCHOR tag=%s count=%d" % (tag, n))
        sys.exit(1)
    return src.replace(old, new, 1)


def main():
    src = open(SRC, encoding="utf-8", errors="surrogateescape").read()
    n = src.count("boot-b-a143")
    if n < 1:
        print("A145_MUTATE_NO_OUTPUT_NAME")
        return 1
    src = src.replace("boot-b-a143", "boot-b-a145")
    src = once(src, A_ANCHOR, PATCH_BLOCK + A_ANCHOR, "patch")
    src = once(src, B_ANCHOR, B_ANCHOR + "\n" + KO_BLOCK, "ko")
    src = once(src, C_ANCHOR, CPIO_BLOCK + C_ANCHOR, "cpio")
    if "boot-b-a143" in src:
        print("A145_MUTATE_LEFTOVER")
        return 1
    open(DST, "w", encoding="utf-8", errors="surrogateescape").write(src)
    print("A145_MUTATE_OK output_names=%d bytes=%d" % (src.count("boot-b-a145"), len(src)))
    return 0


if __name__ == "__main__":
    sys.exit(main())