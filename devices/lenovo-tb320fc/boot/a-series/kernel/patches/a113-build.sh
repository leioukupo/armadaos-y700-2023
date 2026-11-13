#!/bin/bash
# A113 = the A104 kernel, plus an initramfs patch round whose whole purpose is
# to report its own result: the patch log goes to the card in the same boot, the
# in-root diagnostic finds the card by scanning mmcblk partitions, and a state
# summary is repeated on the panel console.
#
# The kernel C code does not move at all: the only input that changes is the
# initramfs source (/tmp/y700/initramfs), where this round adds
#   * an updated /init whose patch hook also passes the SD card device to the patch
#   * /y700-patch.sh, which copies the previous boot's /var/log out of the UFS root
#     onto the card, re-arms SDDM autologin into armada-plasma-mobile, drops
#     sddm's three-crash start limit, arms y700-diag.service, and masks the two
#     units that write /KERNEL into the ESP - that ESP is an Android partition.
# The symbol set must stay byte-identical and the DTB stays the A104 one
# (gpu@3d00000 / gmu / adreno SMMU enabled).  Rollback stays
# /tmp/y700/e15/boot-b-a104.img; boot-b-a110.img is the round this one replaces.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
IR=/tmp/y700/initramfs
cd "$K" || exit 1
echo "=== a113 build start $(date -u) ==="

[ -s /tmp/y700/e15/boot-b-a104.img ] || { echo NO_A104_ROLLBACK_IMAGE; exit 1; }
[ -s "$B/armada-boot/vmlinuz" ] || { echo NO_A104_KERNEL; exit 1; }
[ -s "$B/armada-boot/vmlinuz.a104" ] || cp -f "$B/armada-boot/vmlinuz" "$B/armada-boot/vmlinuz.a104"
[ -s "$B/a1.dtb" ] || { echo NO_DTB; exit 1; }
[ -s "$B/nm-a104.txt" ] || { echo NO_A104_NM_BASELINE; exit 1; }
[ -s "$B/strings-a104.txt" ] || { echo NO_A104_STRINGS_BASELINE; exit 1; }
sha256sum "$B/armada-boot/vmlinuz.a104" "$B/a1.dtb"

# ---- the initramfs gains the hook plus the patch, nothing else moves ----
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }
[ -s /tmp/y700/a113/init-new ] || { echo NO_INIT_SOURCE_STAGED; exit 1; }
[ -s /tmp/y700/a113/patch.sh ] || { echo NO_PATCH_STAGED; exit 1; }
cp -f "$IR/init" "$IR/init.a107bak" 2>/dev/null
cp -f /tmp/y700/a113/init-new "$IR/init" || exit 1
cp -f /tmp/y700/a113/patch.sh "$IR/y700-patch.sh" || exit 1
chmod 0755 "$IR/init" "$IR/y700-patch.sh"
sh -n "$IR/init" || { echo INIT_SYNTAX; exit 1; }
sh -n "$IR/y700-patch.sh" || { echo PATCH_SYNTAX; exit 1; }
grep -q 'A113 PATCH_RUN' "$IR/init" || { echo HOOK_MISSING; exit 1; }
ls -l "$IR/init" "$IR/y700-patch.sh"
# the GPU firmware that A104 put in here must still be present
for f in lib/firmware/qcom/a730_sqe.fw lib/firmware/qcom/gmu_gen70000.bin \
         lib/firmware/qcom/sm8475/lenovo/tb320fc/a730_zap.mdt; do
	[ -s "$IR/$f" ] || { echo "FW_MISSING $f"; exit 1; }
done

# ---- rebuild: only the embedded cpio changes ----
# The resume shortcut is only sound when the initramfs tree is unchanged since the
# Image was last linked.  A108 hit exactly this: the second A108 build took the
# shortcut, make never ran, and the packed image still carried the first build's
# cpio - the fix under test never reached the board.
IRHASH=$(find "$IR" -type f -printf '%p %s\n' | sort | sha256sum | awk '{print $1}')
[ -s "$B/a113-irhash.txt" ] && PREVIOUS=$(cat "$B/a113-irhash.txt") || PREVIOUS=none
echo "initramfs hash now=$IRHASH recorded=$PREVIOUS"
if [ -s "$B/a113-kernel.img" ] && [ "$IRHASH" = "$PREVIOUS" ]; then
	echo RESUME_KERNEL_ALREADY_REBUILT
	cmp -s arch/arm64/boot/Image "$B/a113-kernel.img" || { echo KERNEL_TREE_DIRTY; exit 1; }
else
	rm -f usr/initramfs_data.cpio usr/initramfs_data.o
	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image > /tmp/y700/kbuild/a113-make.log 2>&1 || { echo MAKE_FAIL; tail -40 /tmp/y700/kbuild/a113-make.log; exit 1; }
	cp -f arch/arm64/boot/Image "$B/a113-kernel.img" || exit 1
fi
echo "$IRHASH" > "$B/a113-irhash.txt"
tail -8 /tmp/y700/kbuild/a113-make.log
for n in y700-patch.sh A113 APPLIED a730_sqe.fw gmu_gen70000.bin a730_zap.mdt; do
	c=$(grep -c "$n" usr/initramfs_data.cpio)
	[ "$c" -ge 1 ] || { echo "CPIO_MISSING $n"; exit 1; }
	echo "cpio contains $n ($c)"
done
nm vmlinux | awk '{print $2, $3}' | sort > "$B/nm-a113.txt" || { echo NM_A113_FAIL; exit 1; }
diff "$B/nm-a104.txt" "$B/nm-a113.txt" > /tmp/y700/kbuild/a113-nm-diff.txt || { echo A113_SYMBOL_DELTA; cat /tmp/y700/kbuild/a113-nm-diff.txt; exit 1; }
wc -l "$B/nm-a113.txt"
strg() { strings "$1" | grep -E '[A-Za-z]{4}[A-Za-z0-9_ ,.:;%()/*+=<>-]{10,}' | grep -v 'SMP PREEMPT' | sort -u; }
strg arch/arm64/boot/Image > "$B/strings-a113.txt" || { echo STRINGS_A113_FAIL; exit 1; }
# The cpio payload itself contributes junk tokens to `strings`, so a strict
# zero-loss diff fails on noise (A113 lost exactly one: OEUEuuEUuuUUyE).  What
# has to survive is the kernel's own vocabulary - checked by name - plus a loss
# count small enough that nothing real can hide inside it.
comm -23 "$B/strings-a104.txt" "$B/strings-a113.txt" > /tmp/y700/kbuild/a113-strings-lost.txt
LOST=$(wc -l < /tmp/y700/kbuild/a113-strings-lost.txt)
echo "strings a104=$(wc -l < $B/strings-a104.txt) a113=$(wc -l < $B/strings-a113.txt) lost=$LOST"
[ "$LOST" -le 4 ] || { echo A113_STRING_LOSS_TOO_MANY; head -30 /tmp/y700/kbuild/a113-strings-lost.txt; exit 1; }
for m in 'finger input ready' 'global state already finalized' 'Zap shader not enabled' 'novatek,nt36523n-spi' 'a730_sqe.fw' 'gmu_gen70000.bin' 'a730_zap.mdt' 'adreno' 'qcom,sm8450'; do
	strings arch/arm64/boot/Image | grep -q "$m" || { echo "A104_STRING_GONE $m"; exit 1; }
done
echo "kernel vocabulary intact"
strings arch/arm64/boot/Image | grep -q 'finger input ready' || { echo TOUCH_DRIVER_LOST; exit 1; }
# the kernel compresses the embedded cpio, so its text is NOT findable with
# strings on the Image - the cpio itself is the place to assert on.
grep -q 'A113 PATCH_RUN' usr/initramfs_data.cpio || { echo A113_HOOK_LOST; exit 1; }
grep -q 'armada-plasma-mobile.desktop' usr/initramfs_data.cpio || { echo A113_PATCH_MISSING_SESSION; exit 1; }
grep -q 'y700-resize.service' usr/initramfs_data.cpio || { echo A113_PATCH_MISSING_RESIZE; exit 1; }
grep -q 'StartLimitIntervalSec=0' usr/initramfs_data.cpio || { echo A113_PATCH_NO_STARTLIMIT; exit 1; }
grep -q 'y700-diag.service' usr/initramfs_data.cpio || { echo A113_PATCH_NO_DIAG; exit 1; }
grep -q 'y700-out' usr/initramfs_data.cpio || { echo A113_PATCH_NO_RETRIEVE; exit 1; }
grep -q 'armada-bootimg-sync' usr/initramfs_data.cpio || { echo A113_PATCH_NO_ESP_MASK; exit 1; }
grep -q 'FALLBACK sddm is dead' usr/initramfs_data.cpio || { echo A113_PATCH_NO_FALLBACK; exit 1; }
grep -q '/usr/lib/systemd/system/sddm.service' usr/initramfs_data.cpio || { echo A113_PATCH_WANTS_NOT_ABSOLUTE; exit 1; }
grep -q 'journal.tar' usr/initramfs_data.cpio || { echo A113_PATCH_NO_JOURNAL; exit 1; }
grep -q 'DANGLING' usr/initramfs_data.cpio || { echo A113_PATCH_NO_WANTS_CHECK; exit 1; }
grep -q 'y700-diag2.txt' usr/initramfs_data.cpio || { echo A113_DIAG_NOT_TWICE; exit 1; }
grep -q 'chmod 0755 "$R/usr/local/bin/y700-diag.sh"' usr/initramfs_data.cpio || { echo A113_DIAG_NOT_EXECUTABLE; exit 1; }
grep -q 'rm -rf /mnt/card/y700-out/journal' usr/initramfs_data.cpio || { echo A113_NO_JOURNAL_CLEANUP; exit 1; }
grep -q 'PATCHLOG on card ok' usr/initramfs_data.cpio || { echo A113_PATCHLOG_NOT_SAME_BOOT; exit 1; }
grep -q 'CARD_COPY no y700-out' usr/initramfs_data.cpio || { echo A113_CARD_SCAN_MISSING; exit 1; }
grep -q 'Y700-A113-DIAG' usr/initramfs_data.cpio || { echo A113_DIAG_TAG_MISSING; exit 1; }
grep -q 'wayland-session.log' usr/initramfs_data.cpio || { echo A113_NO_SESSION_LOG; exit 1; }
grep -q 'y700-sddm.txt' usr/initramfs_data.cpio || { echo A113_NO_SDDM_JOURNAL_COPY; exit 1; }
grep -q 'SUM\$S' usr/initramfs_data.cpio || { echo A113_NO_PANEL_SUMMARY; exit 1; }
grep -q 'PSTORE saved' usr/initramfs_data.cpio || { echo A113_NO_PSTORE_SAVE; exit 1; }
grep -q 'CARD rescan=' usr/initramfs_data.cpio || { echo A113_NO_CARD_RESCAN; exit 1; }
grep -q 'timeout 90 /bin/sh /y700-patch.sh' usr/initramfs_data.cpio || { echo A113_NO_PATCH_TIMEOUT; exit 1; }
grep -q 'A113 PST saved' usr/initramfs_data.cpio || { echo A113_NO_INIT_PST_SAVE; exit 1; }
grep -q 'y700-pst-previous.txt' usr/initramfs_data.cpio || { echo A113_NO_PST_COPY; exit 1; }
if grep -q 'JOURNAL write failed' usr/initramfs_data.cpio ; then echo A113_JOURNAL_COPY_STILL_THERE; exit 1; fi
if grep -q 'mount -t pstore pstore /pstore' usr/initramfs_data.cpio ; then echo A113_DEAD_PSTORE_MOUNT; exit 1; fi
echo "initramfs carries the hook and the patch" 
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
ls -l arch/arm64/boot/Image "$B/armada-boot/vmlinuz"

# ---- the DTB is reused untouched: same bytes A104 shipped ----
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a113.dts" || { echo DTC_FAIL; exit 1; }
# the checker needs the same feature flags the generator ran with, otherwise it
# expects nodes the A-series deliberately pinned off (displayport ae90000).
export Y700_GPU=1 Y700_APPS_SMMU=1 Y700_A70=1 Y700_A102=1 Y700_MINIMAL=1
export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
python3 "$B/chk_minimal.py" "$B/chk_a113.dts" || { echo CHK_FAIL; exit 1; }
grep -q 'status = "okay";' <(sed -n '/gpu@3d00000/,/^		};/p' "$B/chk_a113.dts") || { echo GPU_NOT_OKAY; exit 1; }
cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.bin" 2>/dev/null; aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a113.img" || { echo PACK_FAIL; exit 1; }

python3 - "$B/out/boot-b-a113.img" "$B/a1.dtb" <<'PYIMG' || { echo A113_DTB_NOT_IN_IMAGE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('boot image %d bytes, a1.dtb %d bytes, found at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYIMG
# these two live in kernel rodata / the DTB, i.e. uncompressed inside the image;
# the initramfs contents were asserted on usr/initramfs_data.cpio above.
for s in 'a730_sqe.fw' 'qcom,adreno-730'; do
	strings "$B/out/boot-b-a113.img" | grep -q "$s" || { echo "A113_IMAGE_LOST $s"; exit 1; }
	echo "image contains $s"
done
cp -f "$B/out/boot-b-a113.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a113.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a113.img
sha256sum /tmp/y700/e15/boot-b-a113.img
echo "=== a113 end $(date -u) ==="
echo A113_ALL_OK
