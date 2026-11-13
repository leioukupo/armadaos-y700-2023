#!/bin/bash
# A127 prep: move ath11k_pci out of vmlinux into a loadable module.
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
# A127 changes one config line: ATH11K_PCI y -> m.  The ath11k core and the MHI
# bus stay built-in.  The pwrctrl/pwrseq power path also has to stay built-in,
# and it cannot: PCI_PWRCTRL_PWRSEQ is a promptless tristate whose only selector
# was ATH11K_PCI, so kconfig demotes it to m the moment ATH11K_PCI becomes m
# (the first prep run printed A127_CFG_NOT_BUILTIN PCI_PWRCTRL_PWRSEQ).  Without
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

grep -q '^CONFIG_ATH11K=y$' .config || { echo A127_BASE_NOT_AS_EXPECTED; exit 1; }
# idempotent: an earlier prep run may already have flipped this line
grep -q '^CONFIG_ATH11K_PCI=[ym]$' .config || { echo A127_PCI_NOT_THERE; exit 1; }
sed -i 's/^CONFIG_ATH11K_PCI=.*$/CONFIG_ATH11K_PCI=m/' .config
for c in MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_GENERIC POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN; do
	sed -i "s/^CONFIG_$c=m\$/CONFIG_$c=y/" .config
done
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/y700/a127-olddef.log 2>&1 || { echo OLDDEFCONFIG_FAIL; tail -20 /tmp/y700/a127-olddef.log; exit 1; }
grep -q '^CONFIG_ATH11K_PCI=m$' .config || { echo A127_CFG_PCI_NOT_MODULE; exit 1; }
for c in ATH11K MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_PWRSEQ PCI_PWRCTRL_GENERIC PCIE_QCOM POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN CFG80211 MAC80211 MODULES; do
	grep -q "^CONFIG_$c=y$" .config || { echo "A127_CFG_NOT_BUILTIN $c"; exit 1; }
done
grep -E '^CONFIG_(ATH11K|ATH11K_PCI|ATH11K_AHB|MHI_BUS|QRTR|QRTR_MHI|PCI_PWRCTRL|PCI_PWRCTRL_PWRSEQ|PCI_PWRCTRL_GENERIC|PCIE_QCOM|POWER_SEQUENCING|POWER_SEQUENCING_QCOM_WCN|CFG80211|MAC80211)=' .config
# the DTB stays exactly the A115 bytes; this round must not move the platform
[ -s "$B/a1.dtb" ] || { echo NO_DTB; exit 1; }
cmp -s "$B/a1.dtb" "$B/a1.dtb.a115" || { echo A127_DTB_NOT_A115; sha256sum "$B/a1.dtb" "$B/a1.dtb.a115"; exit 1; }
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a127.dts" 2>/dev/null || { echo DTC_FAIL; exit 1; }
grep -q 'pci17cb,1103' "$B/chk_a127.dts" || { echo A127_WCN_ENDPOINT_MISSING; exit 1; }
grep -q 'qcom,wcn6855-pmu' "$B/chk_a127.dts" || { echo A127_WCN_PMU_MISSING; exit 1; }
# no ath11k firmware in the initramfs this round - build.sh adds only the .ko
if [ -d /tmp/y700/initramfs/lib/firmware/ath11k ] ; then echo A127_UNEXPECTED_ATH11K_FW; exit 1; fi
echo "initramfs firmware dir=[$(ls /tmp/y700/initramfs/lib/firmware 2>/dev/null | tr '\n' ',')] size=$(du -sk /tmp/y700/initramfs | awk '{print $1}')K"
echo A127_PREP_OK