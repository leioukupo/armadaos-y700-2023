#!/bin/bash
# A129 prep: move ath11k_pci out of vmlinux into a loadable module.
#
# A126 settled the diagnosis: the endpoint enumerates (0000:01:00.0), the driver
# dir is present, the root carries every WCN6855 firmware file, and still
#   mhi mhi0: Error loading firmware: -2
#   ath11k_pci 0000:01:00.0: failed to power up mhi: -110
#   probe of 0000:01:00.0 with driver ath11k_pci failed with error -110
# because a built-in driver probes during initcalls, when the only /lib/firmware
# in reach is the initramfs one (3.1M: GPU + novatek).  Putting ath11k firmware
# into the initramfs is exactly what A122-A124 did, and it killed the boot.
#
# A129 changes one config line: ATH11K_PCI y -> m.  The ath11k core and the MHI
# bus stay built-in.  The pwrctrl/pwrseq power path also has to stay built-in,
# and it cannot: PCI_PWRCTRL_PWRSEQ is a promptless tristate whose only selector
# was ATH11K_PCI, so kconfig demotes it to m the moment ATH11K_PCI becomes m
# (the first prep run printed A129_CFG_NOT_BUILTIN PCI_PWRCTRL_PWRSEQ).  Without
# it qcom_pcie host_init creates the pwrctrl device but nothing binds it, so the
# WCN rails never come up.  The fix is one Kconfig line: PCIE_QCOM (a bool,
# always y here) selects PCI_PWRCTRL_PWRSEQ, which decouples the power path from
# the Wi-Fi driver completely.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
[ -s "$B/Kconfig.dwc.a126.keep" ] || cp -f drivers/pci/controller/dwc/Kconfig "$B/Kconfig.dwc.a126.keep"
[ -s "$B/config.a126.keep" ] || cp -f .config "$B/config.a126.keep"

if ! grep -q 'select PCI_PWRCTRL_PWRSEQ' <(sed -n "/^config PCIE_QCOM\$/,/^config PCIE_QCOM_EP\$/p" drivers/pci/controller/dwc/Kconfig) ; then
	python3 - <<'PYKCONFIG' || { echo KCONFIG_EDIT_FAIL; exit 1; }
import sys
p = 'drivers/pci/controller/dwc/Kconfig'
s = open(p, encoding='utf-8').read()
head = 'config PCIE_QCOM\n'
i = s.find(head)
if i < 0:
    sys.exit('no PCIE_QCOM stanza')
j = s.find('\nconfig ', i + 1)
blk = s[i:j]
old = '\tselect PCI_PWRCTRL_GENERIC\n'
if old not in blk:
    sys.exit('no PCI_PWRCTRL_GENERIC line inside PCIE_QCOM')
blk = blk.replace(old, old + '\tselect PCI_PWRCTRL_PWRSEQ\n', 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s[:i] + blk + s[j:])
print('kconfig now pins PCI_PWRCTRL_PWRSEQ from PCIE_QCOM')
PYKCONFIG
else
	echo 'kconfig already pins PCI_PWRCTRL_PWRSEQ'
fi
sed -n "/^config PCIE_QCOM\$/,/^config PCIE_QCOM_EP\$/p" drivers/pci/controller/dwc/Kconfig

grep -q '^CONFIG_ATH11K=y$' .config || { echo A129_BASE_NOT_AS_EXPECTED; exit 1; }
# idempotent: an earlier prep run may already have flipped this line
grep -q '^CONFIG_ATH11K_PCI=[ym]$' .config || { echo A129_PCI_NOT_THERE; exit 1; }
sed -i 's/^CONFIG_ATH11K_PCI=.*$/CONFIG_ATH11K_PCI=y/' .config
for c in MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_GENERIC POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN; do
	sed -i "s/^CONFIG_$c=m\$/CONFIG_$c=y/" .config
done
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/y700/a129-olddef.log 2>&1 || { echo OLDDEFCONFIG_FAIL; tail -20 /tmp/y700/a129-olddef.log; exit 1; }
grep -q '^CONFIG_ATH11K_PCI=y$' .config || { echo A129_CFG_PCI_NOT_BUILTIN; exit 1; }
for c in ATH11K MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_PWRSEQ PCI_PWRCTRL_GENERIC PCIE_QCOM POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN CFG80211 MAC80211 MODULES; do
	grep -q "^CONFIG_$c=y$" .config || { echo "A129_CFG_NOT_BUILTIN $c"; exit 1; }
done
grep -E '^CONFIG_(ATH11K|ATH11K_PCI|ATH11K_AHB|MHI_BUS|QRTR|QRTR_MHI|PCI_PWRCTRL|PCI_PWRCTRL_PWRSEQ|PCI_PWRCTRL_GENERIC|PCIE_QCOM|POWER_SEQUENCING|POWER_SEQUENCING_QCOM_WCN|CFG80211|MAC80211)=' .config
# the DTB stays exactly the A115 bytes; this round must not move the platform
[ -s "$B/a1.dtb" ] || { echo NO_DTB; exit 1; }
cmp -s "$B/a1.dtb" "$B/a1.dtb.a115" || { echo A129_DTB_NOT_A115; sha256sum "$B/a1.dtb" "$B/a1.dtb.a115"; exit 1; }
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a129.dts" 2>/dev/null || { echo DTC_FAIL; exit 1; }
grep -q 'pci17cb,1103' "$B/chk_a129.dts" || { echo A129_WCN_ENDPOINT_MISSING; exit 1; }
grep -q 'qcom,wcn6855-pmu' "$B/chk_a129.dts" || { echo A129_WCN_PMU_MISSING; exit 1; }
# no ath11k firmware in the initramfs this round - build.sh adds only the .ko
# A129: an ath11k directory in the initramfs is the point of the round (baked below)
echo "initramfs firmware dir=[$(ls /tmp/y700/initramfs/lib/firmware 2>/dev/null | tr '\n' ',')] size=$(du -sk /tmp/y700/initramfs | awk '{print $1}')K"
# ---- A129: pay for the firmware with kernel text ----
# CONFIG_KALLSYMS_ALL only adds the names of data symbols to /proc/kallsyms; the
# text symbols that initcall_debug and every backtrace here depend on stay.  It
# is worth 2752512 bytes of Image, measured on this exact tree.
./scripts/config --file .config -d KALLSYMS_ALL
grep -q '^CONFIG_KALLSYMS=y$' .config || { echo A129_KALLSYMS_LOST; exit 1; }
grep -q '^# CONFIG_KALLSYMS_ALL is not set$' .config || { echo A129_KALLSYMS_ALL_STILL_ON; exit 1; }
# the embedded cpio is XZ-compressed instead of gzip: same content, 926776 bytes
# smaller, and CONFIG_XZ_DEC is already built in for the bootloader ramdisk.
./scripts/config --file .config -d INITRAMFS_COMPRESSION_GZIP -e INITRAMFS_COMPRESSION_XZ
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig >> /tmp/y700/a129-olddef.log 2>&1 || { echo A129_OLDDEFCONFIG_FAIL; tail -20 /tmp/y700/a129-olddef.log; exit 1; }
grep -q '^# CONFIG_KALLSYMS_ALL is not set$' .config || { echo A129_KALLSYMS_ALL_BACK; exit 1; }
grep -q '^CONFIG_INITRAMFS_COMPRESSION_XZ=y$' .config || { echo A129_NOT_XZ; exit 1; }
grep -q '^CONFIG_XZ_DEC=y$' .config || { echo A129_XZ_DEC_MISSING; exit 1; }
grep -q '^CONFIG_KALLSYMS=y$' .config || { echo A129_KALLSYMS_BACK; exit 1; }
grep -E '^CONFIG_(KALLSYMS|KALLSYMS_ALL|INITRAMFS_COMPRESSION_XZ|INITRAMFS_COMPRESSION_GZIP|XZ_DEC)=' .config

# ---- A129: the WCN6855 firmware has to be inside the initramfs ----
# ath11k asks for ath11k/WCN6855/hw2.1/{amss.bin,board-2.bin,m3.bin} from the MHI
# power-up, which happens inside the initcall window.  amss.bin/m3.bin/regdb.bin
# are the asphalt-linux set (oneplus/negroni ships the same WCN6855 hw2.1 parts),
# board-2.bin is the Y700 encoding from the stock qca6490 bdwlang.elf.
IR=/tmp/y700/initramfs
FWA=/tmp/y700/fw-asphalt
mkdir -p "$IR/lib/firmware/ath11k/WCN6855/hw2.1" || exit 1
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/amss.bin"  "$IR/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin"  || exit 1
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/m3.bin"     "$IR/lib/firmware/ath11k/WCN6855/hw2.1/m3.bin"     || exit 1
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/regdb.bin" "$IR/lib/firmware/ath11k/WCN6855/hw2.1/regdb.bin" || exit 1
cp -f "$FWA/lenovo/tb320fc/wifi/board-2.bin"         "$IR/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin" || exit 1
# cfg80211 asks for /lib/firmware/regulatory.db from regulatory_init_db(), which
# runs at up=3.6 s - also inside the initramfs, also always failed with -2.
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/regdb.bin" "$IR/lib/firmware/regulatory.db" || exit 1
for f in amss.bin board-2.bin m3.bin regdb.bin; do
	cmp -s "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f" "$FWA/oneplus/negroni/WCN6855/hw2.1/$f" 2>/dev/null && continue
	cmp -s "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f" "$FWA/lenovo/tb320fc/wifi/$f" 2>/dev/null && continue
	echo "A129_FW_COPY_DIFF $f"; exit 1
done
cmp -s "$IR/lib/firmware/regulatory.db" "$FWA/oneplus/negroni/WCN6855/hw2.1/regdb.bin" || { echo A129_REGDB_COPY_DIFF; exit 1; }
for f in amss.bin board-2.bin m3.bin regdb.bin; do
	echo "initramfs fw $f size=$(wc -c < "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f") sha=$(sha256sum "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f" | cut -c1-16)"
done
echo "initramfs regulatory.db size=$(wc -c < "$IR/lib/firmware/regulatory.db")"
# the module of A127/A128 must be gone: a stale .ko in the initramfs would make
# the round ambiguous about which driver ran.
rm -rf "$IR/y700-ko"
[ -e "$IR/y700-ko/ath11k_pci.ko" ] && { echo A129_KO_STILL_IN_INITRAMFS; exit 1; }
echo "initramfs ath11k dir=[$(ls "$IR/lib/firmware/ath11k/WCN6855/hw2.1" | tr '\n' ',')] total=$([ $(du -sk "$IR" | cut -f1) ])K"
echo ATH129_FW_OK
echo A129_PREP_OK