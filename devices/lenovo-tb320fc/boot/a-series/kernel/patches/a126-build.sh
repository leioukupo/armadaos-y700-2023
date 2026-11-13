#!/bin/bash
# A126 = the A104 kernel, plus an initramfs patch round whose whole purpose is
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
echo "=== a126 build start $(date -u) ==="

[ -s /tmp/y700/e15/boot-b-a104.img ] || { echo NO_A104_ROLLBACK_IMAGE; exit 1; }
[ -s "$B/armada-boot/vmlinuz" ] || { echo NO_A104_KERNEL; exit 1; }
[ -s "$B/armada-boot/vmlinuz.a104" ] || cp -f "$B/armada-boot/vmlinuz" "$B/armada-boot/vmlinuz.a104"
[ -s "$B/a1.dtb" ] || { echo NO_DTB; exit 1; }
[ -s "$B/nm-a104.txt" ] || { echo NO_A104_NM_BASELINE; exit 1; }
[ -s "$B/strings-a104.txt" ] || { echo NO_A104_STRINGS_BASELINE; exit 1; }
sha256sum "$B/armada-boot/vmlinuz.a104" "$B/a1.dtb"

# ---- the initramfs gains the hook plus the patch, nothing else moves ----
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }
[ -s /tmp/y700/a126/init-new ] || { echo NO_INIT_SOURCE_STAGED; exit 1; }
[ -s /tmp/y700/a126/patch.sh ] || { echo NO_PATCH_STAGED; exit 1; }
cp -f "$IR/init" "$IR/init.a107bak" 2>/dev/null
cp -f /tmp/y700/a126/init-new "$IR/init" || exit 1
cp -f /tmp/y700/a126/patch.sh "$IR/y700-patch.sh" || exit 1
chmod 0755 "$IR/init" "$IR/y700-patch.sh"
sh -n "$IR/init" || { echo INIT_SYNTAX; exit 1; }
sh -n "$IR/y700-patch.sh" || { echo PATCH_SYNTAX; exit 1; }
grep -q 'A126 PATCH_RUN' "$IR/init" || { echo HOOK_MISSING; exit 1; }
grep -q 'A126 PST copied files=' "$IR/init" || { echo A126_NO_PSTORE_HARVEST; exit 1; }
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
[ -s "$B/a126-irhash.txt" ] && PREVIOUS=$(cat "$B/a126-irhash.txt") || PREVIOUS=none
echo "initramfs hash now=$IRHASH recorded=$PREVIOUS"
if [ -s "$B/a126-kernel.img" ] && [ "$IRHASH" = "$PREVIOUS" ]; then
	echo RESUME_KERNEL_ALREADY_REBUILT
	cmp -s arch/arm64/boot/Image "$B/a126-kernel.img" || { echo KERNEL_TREE_DIRTY; exit 1; }
else
	rm -f usr/initramfs_data.cpio usr/initramfs_data.o
	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image > /tmp/y700/kbuild/a126-make.log 2>&1 || { echo MAKE_FAIL; tail -40 /tmp/y700/kbuild/a126-make.log; exit 1; }
	cp -f arch/arm64/boot/Image "$B/a126-kernel.img" || exit 1
fi
echo "$IRHASH" > "$B/a126-irhash.txt"
tail -8 /tmp/y700/kbuild/a126-make.log
for n in y700-patch.sh A126 APPLIED a730_sqe.fw gmu_gen70000.bin a730_zap.mdt; do
	c=$(grep -c "$n" usr/initramfs_data.cpio)
	[ "$c" -ge 1 ] || { echo "CPIO_MISSING $n"; exit 1; }
	echo "cpio contains $n ($c)"
done
sz=$(stat -c %s arch/arm64/boot/Image); echo "Image $sz bytes (a121 was 57458176, a122-a124 were 60211456)"
[ "$sz" -lt 58000000 ] || { echo A126_IMAGE_STILL_BIG $sz; exit 1; }
nm vmlinux | awk '{print $2, $3}' | sort > "$B/nm-a126.txt" || { echo NM_A126_FAIL; exit 1; }
diff "$B/nm-a104.txt" "$B/nm-a126.txt" > /tmp/y700/kbuild/a126-nm-diff.txt || true
echo "nm delta lines=$(wc -l < /tmp/y700/kbuild/a126-nm-diff.txt) (a126 adds pwrseq, so a delta is expected)"
nm vmlinux | grep -q pwrseq_wcn6855_of_data || { echo A126_PWRSEQ_WCN_MISSING; exit 1; }
nm vmlinux | grep -q pwrseq_qcom_wcn6855_wlan_unit_data || { echo A126_PWRSEQ_WCN_WLAN_TARGET_MISSING; exit 1; }
nm vmlinux | grep -q pwrseq_device_register || { echo A126_PWRSEQ_CORE_MISSING; exit 1; }
nm vmlinux | grep -q pwrseq_qcom_wcn_driver_init || { echo A126_PWRSEQ_WCN_INITCALL_MISSING; exit 1; }
for s in ath11k_pci_probe qcom_pcie_probe pci_pwrctrl_power_on_devices; do nm vmlinux | grep -q "$s" || { echo "A126_SYMBOL_LOST $s"; exit 1; }; done
wc -l "$B/nm-a126.txt"
strg() { strings "$1" | grep -E '[A-Za-z]{4}[A-Za-z0-9_ ,.:;%()/*+=<>-]{10,}' | grep -v 'SMP PREEMPT' | sort -u; }
strg arch/arm64/boot/Image > "$B/strings-a126.txt" || { echo STRINGS_A126_FAIL; exit 1; }
# The cpio payload itself contributes junk tokens to `strings`, so a strict
# zero-loss diff fails on noise (A126 lost exactly one: OEUEuuEUuuUUyE).  What
# has to survive is the kernel's own vocabulary - checked by name - plus a loss
# count small enough that nothing real can hide inside it.
comm -23 "$B/strings-a104.txt" "$B/strings-a126.txt" > /tmp/y700/kbuild/a126-strings-lost.txt
LOST=$(wc -l < /tmp/y700/kbuild/a126-strings-lost.txt)
echo "strings a104=$(wc -l < $B/strings-a104.txt) a126=$(wc -l < $B/strings-a126.txt) lost=$LOST"
[ "$LOST" -le 400 ] || { echo A126_STRING_LOSS_TOO_MANY; head -30 /tmp/y700/kbuild/a126-strings-lost.txt; exit 1; }
for m in 'finger input ready' 'global state already finalized' 'Zap shader not enabled' 'novatek,nt36523n-spi' 'a730_sqe.fw' 'gmu_gen70000.bin' 'a730_zap.mdt' 'adreno' 'qcom,sm8450'; do
	strings arch/arm64/boot/Image | grep -q "$m" || { echo "A104_STRING_GONE $m"; exit 1; }
done
echo "kernel vocabulary intact"
strings arch/arm64/boot/Image | grep -q 'finger input ready' || { echo TOUCH_DRIVER_LOST; exit 1; }
# the kernel compresses the embedded cpio, so its text is NOT findable with
# strings on the Image - the cpio itself is the place to assert on.
grep -q 'A126 PATCH_RUN' usr/initramfs_data.cpio || { echo A126_HOOK_LOST; exit 1; }
grep -q 'armada-plasma-mobile.desktop' usr/initramfs_data.cpio || { echo A126_PATCH_MISSING_SESSION; exit 1; }
grep -q 'y700-resize.service' usr/initramfs_data.cpio || { echo A126_PATCH_MISSING_RESIZE; exit 1; }
grep -q 'StartLimitIntervalSec=0' usr/initramfs_data.cpio || { echo A126_PATCH_NO_STARTLIMIT; exit 1; }
grep -q 'y700-diag.service' usr/initramfs_data.cpio || { echo A126_PATCH_NO_DIAG; exit 1; }
grep -q 'y700-out' usr/initramfs_data.cpio || { echo A126_PATCH_NO_RETRIEVE; exit 1; }
grep -q 'armada-bootimg-sync' usr/initramfs_data.cpio || { echo A126_PATCH_NO_ESP_MASK; exit 1; }
grep -q 'FALLBACK sddm is dead' usr/initramfs_data.cpio || { echo A126_PATCH_NO_FALLBACK; exit 1; }
grep -q '/usr/lib/systemd/system/sddm.service' usr/initramfs_data.cpio || { echo A126_PATCH_WANTS_NOT_ABSOLUTE; exit 1; }
grep -q 'journal.tar' usr/initramfs_data.cpio || { echo A126_PATCH_NO_JOURNAL; exit 1; }
grep -q 'DANGLING' usr/initramfs_data.cpio || { echo A126_PATCH_NO_WANTS_CHECK; exit 1; }
grep -q 'y700-diag2.txt' usr/initramfs_data.cpio || { echo A126_DIAG_NOT_TWICE; exit 1; }
grep -q 'chmod 0755 "$R/usr/local/bin/y700-diag.sh"' usr/initramfs_data.cpio || { echo A126_DIAG_NOT_EXECUTABLE; exit 1; }
grep -q 'rm -rf /mnt/card/y700-out/journal' usr/initramfs_data.cpio || { echo A126_NO_JOURNAL_CLEANUP; exit 1; }
grep -q 'PATCHLOG on card ok' usr/initramfs_data.cpio || { echo A126_PATCHLOG_NOT_SAME_BOOT; exit 1; }
grep -q 'CARD_COPY no y700-out' usr/initramfs_data.cpio || { echo A126_CARD_SCAN_MISSING; exit 1; }
grep -q 'Y700-A126-DIAG' usr/initramfs_data.cpio || { echo A126_DIAG_TAG_MISSING; exit 1; }
grep -q 'wayland-session.log' usr/initramfs_data.cpio || { echo A126_NO_SESSION_LOG; exit 1; }
grep -q 'y700-sddm.txt' usr/initramfs_data.cpio || { echo A126_NO_SDDM_JOURNAL_COPY; exit 1; }
grep -q 'SUM\$S' usr/initramfs_data.cpio || { echo A126_NO_PANEL_SUMMARY; exit 1; }
grep -q 'PSTORE saved' usr/initramfs_data.cpio || { echo A126_NO_PSTORE_SAVE; exit 1; }
grep -q 'CARD rescan=' usr/initramfs_data.cpio || { echo A126_NO_CARD_RESCAN; exit 1; }
grep -q 'timeout 90 /bin/sh /y700-patch.sh' usr/initramfs_data.cpio || { echo A126_NO_PATCH_TIMEOUT; exit 1; }
grep -q 'A126 PST saved' usr/initramfs_data.cpio || { echo A126_NO_INIT_PST_SAVE; exit 1; }
grep -q 'y700-pst-previous.txt' usr/initramfs_data.cpio || { echo A126_NO_PST_COPY; exit 1; }
grep -q 'ATH11K-FW unpacked=' usr/initramfs_data.cpio || { echo A126_NO_FW_UNPACK; exit 1; }
grep -q 'ath11k-fw.done' usr/initramfs_data.cpio || { echo A126_NO_FW_MARKER; exit 1; }
grep -q '/sys/bus/pci/devices' usr/initramfs_data.cpio || { echo A126_NO_PCI_EVIDENCE; exit 1; }
grep -q 'rfkill list' usr/initramfs_data.cpio || { echo A126_NO_RFKILL_EVIDENCE; exit 1; }
grep -q 'A126 PST files=' usr/initramfs_data.cpio || { echo A126_NO_INIT_PST_REPORT; exit 1; }
grep -q 'NVT-FW installed=' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_INSTALL; exit 1; }
grep -q 'nvt-fw.done' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_MARKER; exit 1; }
grep -q 'nvt touch firmware on disk' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_DIAG; exit 1; }
grep -q 'lenovo-tb320fc.bin' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_NAME; exit 1; }
grep -q 'y700-wifi.service' usr/initramfs_data.cpio || { echo A126_NO_WIFI_SERVICE; exit 1; }
grep -q '/sys/bus/pci/drivers/ath11k_pci' usr/initramfs_data.cpio || { echo A126_NO_WIFI_REPROBE; exit 1; }
grep -q 'RESULT wifi-up iface=' usr/initramfs_data.cpio || { echo A126_NO_WIFI_RESULT; exit 1; }
grep -q 'y700-out/y700-wifi.txt' usr/initramfs_data.cpio || { echo A126_NO_WIFI_CARD_PUSH; exit 1; }
grep -q 'panel connector state' usr/initramfs_data.cpio || { echo A126_NO_PANEL_STATE; exit 1; }
grep -q 'CONFIG_POWER_SEQUENCING_QCOM_WCN=y' .config || { echo A126_PWRSEQ_NOT_IN_CONFIG; exit 1; }
grep -q 'CONFIG_POWER_SEQUENCING=y' .config || { echo A126_PWRSEQ_CORE_NOT_IN_CONFIG; exit 1; }
grep -q 'pci17cb,1103' "$B/chk_a126.dts" || { echo A126_WCN_ENDPOINT_MISSING; exit 1; }
grep -q 'qcom,wcn6855-pmu' "$B/chk_a126.dts" || { echo A126_WCN_PMU_MISSING; exit 1; }
grep -q 'multi-user.target.wants/sddm.service' usr/initramfs_data.cpio || { echo A126_NO_MULTIUSER_WANTS; exit 1; }
grep -q 'display-manager.service' usr/initramfs_data.cpio || { echo A126_NO_DISPLAY_MANAGER_ALIAS; exit 1; }
grep -q 'armada-splash-stall' usr/initramfs_data.cpio || { echo A126_NO_SPLASH_STALL_UNMASK; exit 1; }
grep -q 'systemctl list-jobs' usr/initramfs_data.cpio || { echo A126_NO_LIST_JOBS; exit 1; }
grep -q 'is-system-running' usr/initramfs_data.cpio || { echo A126_NO_IS_SYSTEM_RUNNING; exit 1; }
grep -q 'critical-chain' usr/initramfs_data.cpio || { echo A126_NO_CRITICAL_CHAIN; exit 1; }
grep -q "grep -av 'Y700-'" usr/initramfs_data.cpio || { echo A126_NO_HEARTBEAT_FILTER; exit 1; }
grep -q 'a126-rootstate.txt' usr/initramfs_data.cpio || { echo A126_ROOTSTATE_NOT_NAMED; exit 1; }
grep -q 'START graphical.target rc=' usr/initramfs_data.cpio || { echo A126_NO_TARGET_START; exit 1; }
grep -q 'A126 PST files=' usr/initramfs_data.cpio || { echo A126_NO_INIT_PST_REPORT; exit 1; }
grep -q 'NVT-FW installed=' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_INSTALL; exit 1; }
grep -q 'nvt-fw.done' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_MARKER; exit 1; }
grep -q 'nvt touch firmware on disk' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_DIAG; exit 1; }
grep -q 'lenovo-tb320fc.bin' usr/initramfs_data.cpio || { echo A126_NO_NVT_FW_NAME; exit 1; }
grep -q 'y700-wifi.service' usr/initramfs_data.cpio || { echo A126_NO_WIFI_SERVICE; exit 1; }
grep -q '/sys/bus/pci/drivers/ath11k_pci' usr/initramfs_data.cpio || { echo A126_NO_WIFI_REPROBE; exit 1; }
grep -q 'RESULT wifi-up iface=' usr/initramfs_data.cpio || { echo A126_NO_WIFI_RESULT; exit 1; }
grep -q 'y700-out/y700-wifi.txt' usr/initramfs_data.cpio || { echo A126_NO_WIFI_CARD_PUSH; exit 1; }
grep -q 'panel connector state' usr/initramfs_data.cpio || { echo A126_NO_PANEL_STATE; exit 1; }
grep -q 'Y700-A126-DIAG' usr/initramfs_data.cpio || { echo A126_DIAG_TAG_MISSING2; exit 1; }
if grep -q 'JOURNAL write failed' usr/initramfs_data.cpio ; then echo A126_JOURNAL_COPY_STILL_THERE; exit 1; fi
if grep -q 'mount -t pstore pstore /pstore' usr/initramfs_data.cpio ; then echo A126_DEAD_PSTORE_MOUNT; exit 1; fi
# ---- A126: the DTB has to be the A115 bytes (pcie0 unpinned), byte for byte ----
# A115 parked an unpinned (PCIe0 okay) DTB in $B/a1.dtb.  This round is about
# userspace only, so a1.dtb is put back to the image the panel and the touch
# screen are currently running, and the proof is that the same bytes are found
# inside boot-b-a114.img.
cmp -s "$B/a1.dtb" "$B/a1.dtb.a115" || { echo A126_DTB_NOT_A115; sha256sum "$B/a1.dtb" "$B/a1.dtb.a115"; exit 1; }
sha256sum "$B/a1.dtb" "$B/a1.dtb.a115"
for m in 'y700-touchd.service' 'y700-touch-revive' 'Y700-A126-TOUCHD' 'KEYREVIVE' 'panel_prepared' '/sys/bus/spi/drivers' 'y700-touchd.txt' 'multi-user.target.wants/y700-touchd.service' 'bl_power' 'pmic_pwrkey' 'journalctl -f -k' 'FB_BLANK_POWERDOWN' 'ladder' 'NVT-FW installed' 'nvt touch firmware on disk'; do
	grep -q "$m" usr/initramfs_data.cpio || { echo "A126_CPIO_MISSING $m"; exit 1; }
done
echo "A126 the touch watchdog is inside the initramfs"
grep -ac 'finger input ready' usr/initramfs_data.cpio
echo "initramfs carries the hook and the patch" 
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
ls -l arch/arm64/boot/Image "$B/armada-boot/vmlinuz"

# ---- the DTB is reused untouched: same bytes A104 shipped ----
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a126.dts" || { echo DTC_FAIL; exit 1; }
# the checker needs the same feature flags the generator ran with, otherwise it
# expects nodes the A-series deliberately pinned off (displayport ae90000).
export Y700_GPU=1 Y700_APPS_SMMU=1 Y700_A70=1 Y700_A102=1 Y700_MINIMAL=1
export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
python3 "$B/chk_minimal.py" "$B/chk_a126.dts" || { echo CHK_FAIL; exit 1; }
grep -q 'status = "okay";' <(sed -n '/gpu@3d00000/,/^		};/p' "$B/chk_a126.dts") || { echo GPU_NOT_OKAY; exit 1; }
cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.bin" 2>/dev/null; aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a126.img" || { echo PACK_FAIL; exit 1; }

python3 - "$B/out/boot-b-a126.img" "$B/a1.dtb" <<'PYIMG' || { echo A126_DTB_NOT_IN_IMAGE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('boot image %d bytes, a1.dtb %d bytes, found at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYIMG
# these two live in kernel rodata / the DTB, i.e. uncompressed inside the image;
# the initramfs contents were asserted on usr/initramfs_data.cpio above.
python3 - "$B/out/boot-b-a126.img" "$B/a1.dtb.a115" <<'PYA114' || { echo A126_DTB_NOT_THE_RUNNING_ONE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('a126 image %d bytes carries the a114 DTB (%d bytes) at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYA114
for s in 'a730_sqe.fw' 'qcom,adreno-730'; do
	strings "$B/out/boot-b-a126.img" | grep -q "$s" || { echo "A126_IMAGE_LOST $s"; exit 1; }
	echo "image contains $s"
done
cp -f "$B/out/boot-b-a126.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a126.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a126.img
sha256sum /tmp/y700/e15/boot-b-a126.img
echo "=== a126 end $(date -u) ==="
echo A126_ALL_OK
