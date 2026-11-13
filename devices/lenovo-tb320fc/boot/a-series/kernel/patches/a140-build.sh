#!/bin/bash
# A131 = the A104 kernel, plus an initramfs patch round whose whole purpose is
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
echo "=== a134 build start $(date -u) ==="

[ -s /tmp/y700/e15/boot-b-a104.img ] || { echo NO_A104_ROLLBACK_IMAGE; exit 1; }
[ -s "$B/armada-boot/vmlinuz" ] || { echo NO_A104_KERNEL; exit 1; }
[ -s "$B/armada-boot/vmlinuz.a104" ] || cp -f "$B/armada-boot/vmlinuz" "$B/armada-boot/vmlinuz.a104"
[ -s "$B/a1.dtb" ] || { echo NO_DTB; exit 1; }
[ -s "$B/nm-a104.txt" ] || { echo NO_A104_NM_BASELINE; exit 1; }
[ -s "$B/strings-a104.txt" ] || { echo NO_A104_STRINGS_BASELINE; exit 1; }
sha256sum "$B/armada-boot/vmlinuz.a104" "$B/a1.dtb"
# ---- A140: put the audio protection domains back -------------------------
# apr's of_register_apr_devices() creates a GPR service only once the PDR
# lookup for its qcom,protection-domain resolves, and that lookup needs the
# in-kernel servreg locator - the qcom_pd_mapper module, which A131..A139 never
# shipped.  So A138 removed the property to get the devices at all, and the
# ADSP was never told (through the PDR notifier it publishes as QMI service 66)
# that the AP expects msm/adsp/audio_pd - SPF stayed down and APM_CMD_GET_SPF_STATE
# timed out for every probe.  Restore the pre-A138 blob (the running a139 bytes
# plus exactly those two properties) and ship qcom_pd_mapper ahead of
# qcom_q6v5_pas, so the ADSP boots with the mapper bound.
GP=/soc/remoteproc@3000000/glink-edge/gpr
PRE="$B/a1.dtb.pre-a138"
[ -s "$PRE" ] || { echo A140_NO_PRE138; exit 1; }
rm -f "$B/a1.dtb.a140"
cp -f "$PRE" "$B/a1.dtb.a140" || exit 1
for NP in "$GP/service@1" "$GP/service@2" ; do
	fdtget "$B/a1.dtb.a140" "$NP" qcom,protection-domain >/dev/null 2>&1 || { echo "A140_PD_ABSENT $NP"; exit 1; }
done
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb.a140" > /tmp/y700/a140-pd.dts 2>/dev/null || { echo A140_DTB_UNREADABLE; exit 1; }
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb.a139" > /tmp/y700/a140-a139.dts 2>/dev/null || { echo A140_A139_UNREADABLE; exit 1; }
N=$(grep -c 'qcom,protection-domain' /tmp/y700/a140-pd.dts)
[ "$N" = 3 ] || { echo "A140_PD_COUNT=$N"; exit 1; }
D=$(diff /tmp/y700/a140-a139.dts /tmp/y700/a140-pd.dts | grep -ac '^[<>]')
[ "$D" = 2 ] || { echo "A140_DTB_DELTA=$D"; exit 1; }
echo "A140 dtb bytes=$(stat -c %s "$B/a1.dtb.a140") protection-domain=$N delta-vs-a139=$D"
python3 - "$B/a1.dtb.a140" "$B/a1.dtb.info" <<'PYINFO'
import re, sys
blob = open(sys.argv[1], 'rb').read()
magic = bytes.fromhex('%08x%08x' % (0xDEADBEEF, 0xCAFEBABE))
hits = [m.start() for m in re.finditer(re.escape(magic), blob)]
assert len(hits) == 1, 'A140 placeholder hits=%s' % [hex(h) for h in hits]
open(sys.argv[2], 'w').write('size=%d\nplaceholder_off=%d\n' % (len(blob), hits[0]))
print('A140 dtb.info size=%d placeholder_off=%d' % (len(blob), hits[0]))
PYINFO
cp -f "$B/a1.dtb.a140" "$B/a1.dtb" || exit 1
sha256sum "$B/a1.dtb.a140" "$PRE"
echo "A140 the two GPR audio services wait for their protection domain again and the mapper is shipped"


# ---- the initramfs gains the hook plus the patch, nothing else moves ----
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }
[ -s /tmp/y700/a140/init-new ] || { echo NO_INIT_SOURCE_STAGED; exit 1; }
[ -s /tmp/y700/a140/patch.sh ] || { echo NO_PATCH_STAGED; exit 1; }
[ -s /tmp/y700/a140/y700-audio.sh ] || { echo NO_AUDIO_SCRIPT_STAGED; exit 1; }
cp -f "$IR/init" "$IR/init.a107bak" 2>/dev/null
cp -f /tmp/y700/a140/init-new "$IR/init" || exit 1
cp -f /tmp/y700/a140/patch.sh "$IR/y700-patch.sh" || exit 1
chmod 0755 "$IR/init" "$IR/y700-patch.sh"
cp -f /tmp/y700/a140/y700-audio.sh "$IR/y700-audio.sh" || exit 1
chmod 0755 "$IR/y700-audio.sh"
sh -n "$IR/y700-audio.sh" || { echo AUDIO_SYNTAX; exit 1; }
grep -q "A131 KO audio installed" "$IR/y700-patch.sh" || { echo A131_PATCH_NO_AUDIO_BLOCK; exit 1; }
sh -n "$IR/init" || { echo INIT_SYNTAX; exit 1; }
sh -n "$IR/y700-patch.sh" || { echo PATCH_SYNTAX; exit 1; }
grep -q 'A131 PATCH_RUN' "$IR/init" || { echo HOOK_MISSING; exit 1; }
grep -q 'A131 PST copied files=' "$IR/init" || { echo A131_NO_PSTORE_HARVEST; exit 1; }
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
[ -s "$B/a131-irhash.txt" ] && PREVIOUS=$(cat "$B/a131-irhash.txt") || PREVIOUS=none
echo "initramfs hash now=$IRHASH recorded=$PREVIOUS"
if [ -s "$B/a131-kernel.img" ] && [ "$IRHASH" = "$PREVIOUS" ]; then
	echo RESUME_KERNEL_ALREADY_REBUILT
	cmp -s arch/arm64/boot/Image "$B/a131-kernel.img" || { echo KERNEL_TREE_DIRTY; exit 1; }
else
	rm -f usr/initramfs_data.cpio usr/initramfs_data.o
	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j${JOBS:-24} Image > /tmp/y700/kbuild/a131-make.log 2>&1 || { echo MAKE_FAIL; tail -40 /tmp/y700/kbuild/a131-make.log; exit 1; }
	cp -f arch/arm64/boot/Image "$B/a131-kernel.img" || exit 1
fi
echo "$IRHASH" > "$B/a131-irhash.txt"
tail -8 /tmp/y700/kbuild/a131-make.log
# ---- A131: ath11k_pci lives in a module; build it, ship it in the initramfs ----
# A plain `make Image` never runs modpost, so Module.symvers does not exist and an
# `M=` build dies with "No rule to make target ath11k_pci.ko" (modules.order is
# only generated from the root modules.order).  The standard `make modules` is the
# honest way in: 712 =m modules, incremental, and it produces both Module.symvers
# and ath11k_pci.ko - which is also the proof that modpost resolved every symbol
# the module needs out of the built-in ath11k core.
grep -q '^CONFIG_ATH11K=y$' .config || { echo A131_ATH11K_CORE_NOT_BUILTIN; exit 1; }
grep -q '^CONFIG_ATH11K_PCI=m$' .config || { echo A131_ATH11K_PCI_NOT_MODULE; exit 1; }
for c in MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_PWRSEQ PCI_PWRCTRL_GENERIC POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN; do
	grep -q "^CONFIG_$c=y$" .config || { echo "A131_PWR_PATH_NOT_BUILTIN $c"; exit 1; }
done
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j${JOBS:-24} modules > /tmp/y700/kbuild/a131-modules.log 2>&1 || { echo A131_MODULES_FAIL; tail -40 /tmp/y700/kbuild/a131-modules.log; exit 1; }
[ -s Module.symvers ] || { echo A131_NO_MODULE_SYMS; exit 1; }
echo "Module.symvers lines=$(wc -l < Module.symvers) undefined_warnings=$(grep -c 'WARNING: modpost.*undefined' /tmp/y700/kbuild/a131-modules.log)"
# ---- A131: the audio chain is modules; they ride in the initramfs ----
# ATH11K_PCI stays a module (A130 proved that is the only way MHI ever sees its
# firmware) and the ADSP chain joins it: smp2p (this tree keeps the driver in
# drivers/soc/qcom/smp2p.c, so the module is smp2p.ko, not qcom_smp2p.ko),
# qcom_q6v5_pas, the q6/AudioReach set, CS35L45 and the sc8280xp machine.
# There is no modules.dep on the board and insmod runs in one explicit order, so
# every undefined symbol of a shipped module must come either from vmlinux or
# from another shipped module - the union of the SHIPPED set, not of every .ko
# the tree happens to build.
AUDIO_KOS="smp2p qcom_pil_info qcom_glink_smem qcom_common qcom_pd_mapper qcom_q6v5 qcom_q6v5_pas snd-soc-qcom-common snd-q6dsp-common cs_dsp snd-soc-wm-adsp snd-soc-qcom-sdw q6core snd-q6apm q6apm-lpass-dais q6prm q6prm-clocks q6apm-dai snd-soc-cs35l45 snd-soc-cs35l45-i2c snd-soc-sc8280xp"
KREL=$(cat include/config/kernel.release)
rm -rf "$IR/y700-ko" || exit 1
mkdir -p "$IR/y700-ko" || exit 1
: > "$B/ko-list.txt"
for k in ath11k_pci $AUDIO_KOS ; do
    src=$(find drivers sound -name "$k.ko" -print 2>/dev/null | head -1)
    [ -n "$src" ] || { echo "A131_KO_NOT_BUILT $k"; tail -20 /tmp/y700/kbuild/a131-modules.log; exit 1; }
    echo "$k $src" >> "$B/ko-list.txt"
done
NKO=$(wc -l < "$B/ko-list.txt")
echo "ko resolved=$NKO"
nm vmlinux | awk '{print $NF}' | sort -u > "$B/vml-all.txt"
: > "$B/staged-def.txt"
while read -r _k _src ; do nm --defined-only "$_src" | awk '{print $NF}' >> "$B/staged-def.txt" ; done < "$B/ko-list.txt"
sort -u "$B/vml-all.txt" "$B/staged-def.txt" > "$B/syms-all.txt"
echo "syms vmlinux=$(wc -l < "$B/vml-all.txt") staged=$(wc -l < "$B/staged-def.txt") union=$(wc -l < "$B/syms-all.txt")"
_ok=0; _bad=0
while read -r k src ; do
    verm=$(modinfo -F vermagic "$src" 2>/dev/null)
    case "$verm" in
        "$KREL"*) : ;;
        *) echo "A131_KO_VERMAGIC $k [$verm] vs $KREL"; _bad=$((_bad + 1)); continue ;;
    esac
    nm -u "$src" | awk '{print $NF}' | sort -u > "$B/ko-undef.txt"
    UNDEF=$(comm -23 "$B/ko-undef.txt" "$B/syms-all.txt" | tr "
" " ")
    echo "ko $k src=$src size=$(stat -c %s "$src") vermagic=[$verm] undef=$(wc -l < "$B/ko-undef.txt") missing=[$UNDEF]"
    if [ -n "$UNDEF" ] ; then echo "A131_KO_UNDEFINED $k"; _bad=$((_bad + 1)); continue; fi
    cp -f "$src" "$IR/y700-ko/$k.ko" || exit 1
    _ok=$((_ok + 1))
done < "$B/ko-list.txt"
echo "ko staged=$_ok bad=$_bad dir=[$(ls "$IR/y700-ko" 2>/dev/null | tr "
" ",")]"
[ "$_ok" = 22 ] || { echo A131_KO_COUNT=$_ok; exit 1; }
[ "$_bad" = 0 ] || { echo A131_KO_BAD=$_bad; exit 1; }
grep -q "AUDKO=" "$IR/y700-patch.sh" || { echo A131_PATCH_DOES_NOT_INSTALL_AUDIO_KO; exit 1; }
grep -q "y700-ko/ath11k_pci.ko" "$IR/y700-patch.sh" || { echo A131_PATCH_DOES_NOT_INSTALL_KO; exit 1; }
sha256sum "$IR"/y700-ko/*.ko | head -20
# the initramfs gained a file, so the embedded cpio is linked into Image again
rm -f usr/initramfs_data.cpio usr/initramfs_data.o
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j${JOBS:-24} Image >> /tmp/y700/kbuild/a131-make2.log 2>&1 || { echo A131_MAKE2_FAIL; tail -40 /tmp/y700/kbuild/a131-make2.log; exit 1; }
tail -6 /tmp/y700/kbuild/a131-make2.log
IRHASH=$(find "$IR" -type f -printf '%p %s\n' | sort | sha256sum | awk '{print $1}')
echo "$IRHASH" > "$B/a131-irhash.txt"
cp -f arch/arm64/boot/Image "$B/a131-kernel.img" || exit 1
echo "initramfs hash after the .ko=$IRHASH"

for n in y700-patch.sh y700-audio.sh A131 APPLIED a730_sqe.fw gmu_gen70000.bin a730_zap.mdt; do
	c=$(grep -c "$n" usr/initramfs_data.cpio)
	[ "$c" -ge 1 ] || { echo "CPIO_MISSING $n"; exit 1; }
	echo "cpio contains $n ($c)"
done
sz=$(stat -c %s arch/arm64/boot/Image); echo "Image $sz bytes (a121 was 57458176, a122-a124 were 60211456)"
# A131 ships twelve .ko files inside the cpio, so the Image sits a few MB above the
# A128 baseline.  A129 proved size is not what kills the boot (its Image was smaller
# than A128 and died the same way); the boot partition is 100663296 bytes and the DTB
# is appended behind the Image, so this stays far below the ceiling.
[ "$sz" -lt 62000000 ] || { echo A131_IMAGE_STILL_BIG $sz; exit 1; }
nm vmlinux | awk '{print $2, $3}' | sort > "$B/nm-a131.txt" || { echo NM_A131_FAIL; exit 1; }
diff "$B/nm-a104.txt" "$B/nm-a131.txt" > /tmp/y700/kbuild/a131-nm-diff.txt || true
echo "nm delta lines=$(wc -l < /tmp/y700/kbuild/a131-nm-diff.txt) (a131 adds pwrseq, so a delta is expected)"
nm vmlinux | grep -q pwrseq_wcn6855_of_data || { echo A131_PWRSEQ_WCN_MISSING; exit 1; }
nm vmlinux | grep -q pwrseq_qcom_wcn6855_wlan_unit_data || { echo A131_PWRSEQ_WCN_WLAN_TARGET_MISSING; exit 1; }
nm vmlinux | grep -q pwrseq_device_register || { echo A131_PWRSEQ_CORE_MISSING; exit 1; }
nm vmlinux | grep -q pwrseq_qcom_wcn_driver_init || { echo A131_PWRSEQ_WCN_INITCALL_MISSING; exit 1; }
for s in ath11k_core_qmi_firmware_ready ath11k_hal_srng_init qcom_pcie_probe pci_pwrctrl_power_on_devices pci_pwrctrl_create_devices; do nm vmlinux | grep -q "$s" || { echo "A131_SYMBOL_LOST $s"; exit 1; }; done
n=$(nm vmlinux | grep -c ' ath11k_'); echo "ath11k core symbols in vmlinux=$n (a126 had 811, 56 of them ath11k_pci)"
[ "$n" -ge 700 ] || { echo A131_ATH11K_CORE_LOST $n; exit 1; }
if nm vmlinux | grep -q ath11k_pci_probe ; then echo A131_ATH11K_PCI_STILL_BUILTIN; exit 1; fi
echo "ath11k_pci glue is out of vmlinux, as intended"
wc -l "$B/nm-a131.txt"
strg() { strings "$1" | grep -E '[A-Za-z]{4}[A-Za-z0-9_ ,.:;%()/*+=<>-]{10,}' | grep -v 'SMP PREEMPT' | sort -u; }
strg arch/arm64/boot/Image > "$B/strings-a131.txt" || { echo STRINGS_A131_FAIL; exit 1; }
# The cpio payload itself contributes junk tokens to `strings`, so a strict
# zero-loss diff fails on noise (A131 lost exactly one: OEUEuuEUuuUUyE).  What
# has to survive is the kernel's own vocabulary - checked by name - plus a loss
# count small enough that nothing real can hide inside it.
comm -23 "$B/strings-a104.txt" "$B/strings-a131.txt" > /tmp/y700/kbuild/a131-strings-lost.txt
LOST=$(wc -l < /tmp/y700/kbuild/a131-strings-lost.txt)
echo "strings a104=$(wc -l < $B/strings-a104.txt) a131=$(wc -l < $B/strings-a131.txt) lost=$LOST"
[ "$LOST" -le 400 ] || { echo A131_STRING_LOSS_TOO_MANY; head -30 /tmp/y700/kbuild/a131-strings-lost.txt; exit 1; }
for m in 'finger input ready' 'global state already finalized' 'Zap shader not enabled' 'novatek,nt36523n-spi' 'a730_sqe.fw' 'gmu_gen70000.bin' 'a730_zap.mdt' 'adreno' 'qcom,sm8450'; do
	strings arch/arm64/boot/Image | grep -q "$m" || { echo "A104_STRING_GONE $m"; exit 1; }
done
echo "kernel vocabulary intact"
strings arch/arm64/boot/Image | grep -q 'finger input ready' || { echo TOUCH_DRIVER_LOST; exit 1; }
# the kernel compresses the embedded cpio, so its text is NOT findable with
# strings on the Image - the cpio itself is the place to assert on.
grep -q 'A131 PATCH_RUN' usr/initramfs_data.cpio || { echo A131_HOOK_LOST; exit 1; }
grep -q 'armada-plasma-mobile.desktop' usr/initramfs_data.cpio || { echo A131_PATCH_MISSING_SESSION; exit 1; }
grep -q 'y700-resize.service' usr/initramfs_data.cpio || { echo A131_PATCH_MISSING_RESIZE; exit 1; }
grep -q 'StartLimitIntervalSec=0' usr/initramfs_data.cpio || { echo A131_PATCH_NO_STARTLIMIT; exit 1; }
grep -q 'y700-diag.service' usr/initramfs_data.cpio || { echo A131_PATCH_NO_DIAG; exit 1; }
grep -q 'y700-out' usr/initramfs_data.cpio || { echo A131_PATCH_NO_RETRIEVE; exit 1; }
grep -q 'armada-bootimg-sync' usr/initramfs_data.cpio || { echo A131_PATCH_NO_ESP_MASK; exit 1; }
grep -q 'FALLBACK sddm is dead' usr/initramfs_data.cpio || { echo A131_PATCH_NO_FALLBACK; exit 1; }
grep -q '/usr/lib/systemd/system/sddm.service' usr/initramfs_data.cpio || { echo A131_PATCH_WANTS_NOT_ABSOLUTE; exit 1; }
grep -q 'journal.tar' usr/initramfs_data.cpio || { echo A131_PATCH_NO_JOURNAL; exit 1; }
grep -q 'DANGLING' usr/initramfs_data.cpio || { echo A131_PATCH_NO_WANTS_CHECK; exit 1; }
grep -q 'y700-diag2.txt' usr/initramfs_data.cpio || { echo A131_DIAG_NOT_TWICE; exit 1; }
grep -q 'chmod 0755 "$R/usr/local/bin/y700-diag.sh"' usr/initramfs_data.cpio || { echo A131_DIAG_NOT_EXECUTABLE; exit 1; }
grep -q 'rm -rf /mnt/card/y700-out/journal' usr/initramfs_data.cpio || { echo A131_NO_JOURNAL_CLEANUP; exit 1; }
grep -q 'PATCHLOG on card ok' usr/initramfs_data.cpio || { echo A131_PATCHLOG_NOT_SAME_BOOT; exit 1; }
grep -q 'CARD_COPY no y700-out' usr/initramfs_data.cpio || { echo A131_CARD_SCAN_MISSING; exit 1; }
grep -q 'Y700-A131-DIAG' usr/initramfs_data.cpio || { echo A131_DIAG_TAG_MISSING; exit 1; }
grep -q 'wayland-session.log' usr/initramfs_data.cpio || { echo A131_NO_SESSION_LOG; exit 1; }
grep -q 'y700-sddm.txt' usr/initramfs_data.cpio || { echo A131_NO_SDDM_JOURNAL_COPY; exit 1; }
grep -q 'SUM\$S' usr/initramfs_data.cpio || { echo A131_NO_PANEL_SUMMARY; exit 1; }
grep -q 'PSTORE saved' usr/initramfs_data.cpio || { echo A131_NO_PSTORE_SAVE; exit 1; }
grep -q 'CARD rescan=' usr/initramfs_data.cpio || { echo A131_NO_CARD_RESCAN; exit 1; }
grep -q 'timeout 90 /bin/sh /y700-patch.sh' usr/initramfs_data.cpio || { echo A131_NO_PATCH_TIMEOUT; exit 1; }
grep -q 'A131 PST saved' usr/initramfs_data.cpio || { echo A131_NO_INIT_PST_SAVE; exit 1; }
grep -q 'y700-pst-previous.txt' usr/initramfs_data.cpio || { echo A131_NO_PST_COPY; exit 1; }
grep -q 'ATH11K-FW unpacked=' usr/initramfs_data.cpio || { echo A131_NO_FW_UNPACK; exit 1; }
grep -q 'ath11k-fw.done' usr/initramfs_data.cpio || { echo A131_NO_FW_MARKER; exit 1; }
grep -q '/sys/bus/pci/devices' usr/initramfs_data.cpio || { echo A131_NO_PCI_EVIDENCE; exit 1; }
grep -q 'rfkill list' usr/initramfs_data.cpio || { echo A131_NO_RFKILL_EVIDENCE; exit 1; }
grep -q 'A131 PST files=' usr/initramfs_data.cpio || { echo A131_NO_INIT_PST_REPORT; exit 1; }
grep -q 'NVT-FW installed=' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_INSTALL; exit 1; }
grep -q 'nvt-fw.done' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_MARKER; exit 1; }
grep -q 'nvt touch firmware on disk' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_DIAG; exit 1; }
grep -q 'lenovo-tb320fc.bin' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_NAME; exit 1; }
grep -q 'y700-wifi.service' usr/initramfs_data.cpio || { echo A131_NO_WIFI_SERVICE; exit 1; }
grep -q '/sys/bus/pci/drivers/ath11k_pci' usr/initramfs_data.cpio || { echo A131_NO_WIFI_REPROBE; exit 1; }
grep -q 'RESULT wifi-up iface=' usr/initramfs_data.cpio || { echo A131_NO_WIFI_RESULT; exit 1; }
grep -q 'y700-out/y700-wifi.txt' usr/initramfs_data.cpio || { echo A131_NO_WIFI_CARD_PUSH; exit 1; }
grep -q 'panel connector state' usr/initramfs_data.cpio || { echo A131_NO_PANEL_STATE; exit 1; }
grep -q 'CONFIG_POWER_SEQUENCING_QCOM_WCN=y' .config || { echo A131_PWRSEQ_NOT_IN_CONFIG; exit 1; }
grep -q 'CONFIG_POWER_SEQUENCING=y' .config || { echo A131_PWRSEQ_CORE_NOT_IN_CONFIG; exit 1; }
grep -q 'pci17cb,1103' "$B/chk_a131.dts" || { echo A131_WCN_ENDPOINT_MISSING; exit 1; }
grep -q 'qcom,wcn6855-pmu' "$B/chk_a131.dts" || { echo A131_WCN_PMU_MISSING; exit 1; }
grep -q 'multi-user.target.wants/sddm.service' usr/initramfs_data.cpio || { echo A131_NO_MULTIUSER_WANTS; exit 1; }
grep -q 'display-manager.service' usr/initramfs_data.cpio || { echo A131_NO_DISPLAY_MANAGER_ALIAS; exit 1; }
grep -q 'armada-splash-stall' usr/initramfs_data.cpio || { echo A131_NO_SPLASH_STALL_UNMASK; exit 1; }
grep -q 'systemctl list-jobs' usr/initramfs_data.cpio || { echo A131_NO_LIST_JOBS; exit 1; }
grep -q 'is-system-running' usr/initramfs_data.cpio || { echo A131_NO_IS_SYSTEM_RUNNING; exit 1; }
grep -q 'critical-chain' usr/initramfs_data.cpio || { echo A131_NO_CRITICAL_CHAIN; exit 1; }
grep -q "grep -av 'Y700-'" usr/initramfs_data.cpio || { echo A131_NO_HEARTBEAT_FILTER; exit 1; }
grep -q 'a131-rootstate.txt' usr/initramfs_data.cpio || { echo A131_ROOTSTATE_NOT_NAMED; exit 1; }
grep -q 'START graphical.target rc=' usr/initramfs_data.cpio || { echo A131_NO_TARGET_START; exit 1; }
grep -q 'A131 PST files=' usr/initramfs_data.cpio || { echo A131_NO_INIT_PST_REPORT; exit 1; }
grep -q 'NVT-FW installed=' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_INSTALL; exit 1; }
grep -q 'nvt-fw.done' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_MARKER; exit 1; }
grep -q 'nvt touch firmware on disk' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_DIAG; exit 1; }
grep -q 'lenovo-tb320fc.bin' usr/initramfs_data.cpio || { echo A131_NO_NVT_FW_NAME; exit 1; }
grep -q 'y700-wifi.service' usr/initramfs_data.cpio || { echo A131_NO_WIFI_SERVICE; exit 1; }
grep -q '/sys/bus/pci/drivers/ath11k_pci' usr/initramfs_data.cpio || { echo A131_NO_WIFI_REPROBE; exit 1; }
grep -q 'RESULT wifi-up iface=' usr/initramfs_data.cpio || { echo A131_NO_WIFI_RESULT; exit 1; }
grep -q 'y700-out/y700-wifi.txt' usr/initramfs_data.cpio || { echo A131_NO_WIFI_CARD_PUSH; exit 1; }
grep -q 'panel connector state' usr/initramfs_data.cpio || { echo A131_NO_PANEL_STATE; exit 1; }
grep -q 'Y700-A131-DIAG' usr/initramfs_data.cpio || { echo A131_DIAG_TAG_MISSING2; exit 1; }
if grep -q 'JOURNAL write failed' usr/initramfs_data.cpio ; then echo A131_JOURNAL_COPY_STILL_THERE; exit 1; fi
if grep -q 'mount -t pstore pstore /pstore' usr/initramfs_data.cpio ; then echo A131_DEAD_PSTORE_MOUNT; exit 1; fi
# ---- A131: the DTB has to be the pinned a131 bytes, byte for byte ----
# A115 parked an unpinned (PCIe0 okay) DTB in $B/a1.dtb.  This round is about
# userspace only, so a1.dtb is put back to the image the panel and the touch
# screen are currently running, and the proof is that the same bytes are found
# inside boot-b-a114.img.
cmp -s "$B/a1.dtb" "$B/a1.dtb.a140" || { echo A131_DTB_NOT_PINNED; sha256sum "$B/a1.dtb" "$B/a1.dtb.a140"; exit 1; }
sha256sum "$B/a1.dtb" "$B/a1.dtb.a140" "$B/a1.dtb.a115"
for m in 'y700-touchd.service' 'y700-touch-revive' 'Y700-A131-TOUCHD' 'KEYREVIVE' 'panel_prepared' '/sys/bus/spi/drivers' 'y700-touchd.txt' 'multi-user.target.wants/y700-touchd.service' 'bl_power' 'pmic_pwrkey' 'journalctl -f -k' 'FB_BLANK_POWERDOWN' 'ladder' 'NVT-FW installed' 'nvt touch firmware on disk'; do
	grep -q "$m" usr/initramfs_data.cpio || { echo "A131_CPIO_MISSING $m"; exit 1; }
done
[ -s "$IR/y700-ko/ath11k_pci.ko" ] || { echo A131_KO_NOT_IN_TREE; exit 1; }
if [ -e "$IR/lib/firmware/ath11k" ] ; then echo A131_FW_BAKED_IN_INITRAMFS; exit 1; fi
grep -q 'ath11k-ko.done' usr/initramfs_data.cpio || { echo A131_NO_KO_MARKER; exit 1; }
grep -q '"$INSMOD" /usr/lib/y700/ath11k_pci.ko' usr/initramfs_data.cpio || { echo A131_NO_INSMOD_PATH; exit 1; }
grep -q 'A131 KO installed' usr/initramfs_data.cpio || { echo A131_NO_KO_REPORT; exit 1; }
grep -q 'load start ver=' usr/initramfs_data.cpio || { echo A131_NO_LOAD_TRACE; exit 1; }
if grep -q '> "$DRV/bind"' usr/initramfs_data.cpio ; then echo A131_DEAD_BIND_PATH_STILL_THERE; exit 1; fi
if grep -q '> "$DRV/unbind"' usr/initramfs_data.cpio ; then echo A131_DEAD_UNBIND_PATH_STILL_THERE; exit 1; fi
grep -q 'timeout 240 ' usr/initramfs_data.cpio || { echo A131_NO_LONGER_USES_TIMEOUT; exit 1; }
# (installed-$(basename ...) is already asserted by A131_NO_FILE_MIRROR above)
echo "A131 the module is inside the initramfs and the firmware is not"
grep -q 'pre grp=$(readlink' usr/initramfs_data.cpio || { echo A131_NO_IOMMU_GROUP_PROBE; exit 1; }
grep -q 'decision drvdir=' usr/initramfs_data.cpio || { echo A131_NO_DECISION_LINE; exit 1; }
grep -q 'TimeoutStartSec=infinity' usr/initramfs_data.cpio || { echo A131_NO_START_TIMEOUT; exit 1; }
grep -q 'REGDB installed' usr/initramfs_data.cpio || { echo A131_NO_REGDB_STEP; exit 1; }
grep -q 'regdb.done' usr/initramfs_data.cpio || { echo A131_NO_REGDB_MARKER; exit 1; }
grep -q 'installed-$(basename' usr/initramfs_data.cpio || { echo A131_NO_FILE_MIRROR; exit 1; }
grep -q 'conf_insmod=' usr/initramfs_data.cpio || { echo A131_NO_BRANCH_EVIDENCE; exit 1; }
if grep -c 'L "start up=' usr/initramfs_data.cpio | grep -qv '^1$' ; then echo A131_START_LINE_MULTIPLIED; exit 1; fi
grep -q 'mark mirror-1 done' usr/initramfs_data.cpio || { echo A131_NO_MIRROR1_MARK; exit 1; }
grep -q 'push umount rc=' usr/initramfs_data.cpio || { echo A131_NO_PUSH_MARKS; exit 1; }
grep -q 'timeout 20 mount' usr/initramfs_data.cpio || { echo A131_UNBOUNDED_MOUNT; exit 1; }
echo "A131 the decision-first wifi script and the regdb step are inside the initramfs"
echo "A131 the touch watchdog is inside the initramfs"
grep -q 'Y700-A140-AUD' usr/initramfs_data.cpio || { echo A140_NO_AUDIO_TAG; exit 1; }
grep -q 'y700-cmd.sh' usr/initramfs_data.cpio || { echo A140_NO_AGENT; exit 1; }
grep -q 'aprbind' usr/initramfs_data.cpio || { echo A140_NO_APR_SWEEP; exit 1; }
grep -q 'dtpd()' usr/initramfs_data.cpio || { echo A140_NO_DTB_PROBE; exit 1; }
echo "A140 the audio script carries the apr sweep, the dtb probe and the command agent"

grep -ac 'finger input ready' usr/initramfs_data.cpio
echo "initramfs carries the hook and the patch" 
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
ls -l arch/arm64/boot/Image "$B/armada-boot/vmlinuz"

# ---- the DTB is reused untouched: same bytes A104 shipped ----
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a131.dts" || { echo DTC_FAIL; exit 1; }
# the checker needs the same feature flags the generator ran with, otherwise it
# expects nodes the A-series deliberately pinned off (displayport ae90000).
export Y700_GPU=1 Y700_APPS_SMMU=1 Y700_A70=1 Y700_A102=1 Y700_MINIMAL=1
export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
export Y700_A131=1
export Y700_A132=1
python3 "$B/chk_minimal.py" "$B/chk_a131.dts" || { echo CHK_FAIL; exit 1; }
grep -q 'status = "okay";' <(sed -n '/gpu@3d00000/,/^		};/p' "$B/chk_a131.dts") || { echo GPU_NOT_OKAY; exit 1; }
cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.bin" 2>/dev/null; aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a140.img" || { echo PACK_FAIL; exit 1; }

python3 - "$B/out/boot-b-a140.img" "$B/a1.dtb" <<'PYIMG' || { echo A131_DTB_NOT_IN_IMAGE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('boot image %d bytes, a1.dtb %d bytes, found at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYIMG
# these two live in kernel rodata / the DTB, i.e. uncompressed inside the image;
# the initramfs contents were asserted on usr/initramfs_data.cpio above.
python3 - "$B/out/boot-b-a140.img" "$B/a1.dtb.a140" <<'PYA131' || { echo A131_DTB_NOT_THE_RUNNING_ONE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('the a131 image (%d bytes) carries the pinned DTB (%d bytes) at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYA131
for s in 'a730_sqe.fw' 'qcom,adreno-730'; do
	strings "$B/out/boot-b-a140.img" | grep -q "$s" || { echo "A131_IMAGE_LOST $s"; exit 1; }
	echo "image contains $s"
done
cp -f "$B/out/boot-b-a140.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a140.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a140.img
sha256sum /tmp/y700/e15/boot-b-a140.img
echo "=== a131 end $(date -u) ==="
echo A131_ALL_OK
echo A140_ARTIFACT $(sha256sum /tmp/y700/e15/boot-b-a140.img)
echo A140_ALL_OK
