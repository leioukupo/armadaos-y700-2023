#!/usr/bin/env python3
# A147: derive the a147 round build script from a146.  Same kernel (A145+A146
# battmgr fixes) plus an initramfs patch that refuses suspend on this tablet.
import sys

SRC = "/tmp/y700/a146-build.sh"
DST = "/tmp/y700/a147-build.sh"

STAGE_OLD = 'cp -f /tmp/y700/a143/patch.sh "$IR/y700-patch.sh" || exit 1'
STAGE_NEW = '''# ---- A147: the initramfs patch script gains the sleep refusal ------------
[ -s /tmp/y700/a147/patch.py ] || { echo A147_PATCHER_MISSING; exit 1; }
mkdir -p /tmp/y700/a147
cp -f /tmp/y700/a143/patch.sh /tmp/y700/a147/patch.sh || exit 1
python3 /tmp/y700/a147/patch.py /tmp/y700/a147/patch.sh || { echo A147_PATCH_FAIL; exit 1; }
grep -q "A147 no suspend on this tablet" /tmp/y700/a147/patch.sh || { echo A147_INIT_SRC_LOST; exit 1; }
sh -n /tmp/y700/a147/patch.sh || { echo A147_INIT_SYNTAX; exit 1; }
cp -f /tmp/y700/a147/patch.sh "$IR/y700-patch.sh" || exit 1
echo "A147 initramfs patch script bytes=$(stat -c %s "$IR/y700-patch.sh") with the sleep refusal"'''

GATE_OLD = 'grep -q "A142 unconditional power install" "$IR/y700-patch.sh" || { echo A142_PATCH_NO_POWER_BLOCK; exit 1; }'
GATE_NEW = GATE_OLD + '''
grep -q "A147 no suspend on this tablet" "$IR/y700-patch.sh" || { echo A147_PATCH_NO_SLEEP_BLOCK; exit 1; }
grep -q "AllowSuspend=no" "$IR/y700-patch.sh" || { echo A147_PATCH_NO_ALLOW_SUSPEND; exit 1; }'''

CPIO_OLD = 'echo "A146 the cpio carries the wattage fix"'
CPIO_NEW = CPIO_OLD + '''
grep -q 'AllowSuspend=no' usr/initramfs_data.cpio || { echo A147_SLEEP_OFF_NOT_IN_CPIO; exit 1; }
grep -q 'Y700-A147 sleep-off written' usr/initramfs_data.cpio || { echo A147_TAG_NOT_IN_CPIO; exit 1; }
echo "A147 the cpio carries the sleep refusal"'''


def once(src, old, new, tag):
    n = src.count(old)
    if n != 1:
        print("A147_MUTATE_ANCHOR tag=%s count=%d" % (tag, n))
        sys.exit(1)
    return src.replace(old, new, 1)


def main():
    src = open(SRC, encoding="utf-8", errors="surrogateescape").read()
    n = src.count("boot-b-a146")
    if n < 1:
        print("A147_MUTATE_NO_OUTPUT_NAME")
        return 1
    src = src.replace("boot-b-a146", "boot-b-a147")
    src = once(src, STAGE_OLD, STAGE_NEW, "stage")
    src = once(src, GATE_OLD, GATE_NEW, "gate")
    src = once(src, CPIO_OLD, CPIO_NEW, "cpio")
    if "boot-b-a146" in src:
        print("A147_MUTATE_LEFTOVER")
        return 1
    open(DST, "w", encoding="utf-8", newline="\n").write(src)
    print("A147_MUTATE_OK output_names=%d bytes=%d" % (src.count("boot-b-a147"), len(src)))
    return 0


if __name__ == "__main__":
    sys.exit(main())