#!/bin/bash
# A130: regenerate the boot DTB with the repaired strip_iommu_refs(), and prove that
# the device-tree delta against the A115 baseline is exactly the two iommu-map
# properties - nothing else may move, because A115 is what the panel, the touch
# screen and the UFS root are currently running on.
#
# The property buys: qcom_pcie_config_sid_1_9_0() (ops_1_9_0, i.e.
# qcom,pcie-sm8450-pcie0) programs the PARF BDF-to-SID table from iommu-map.
# Without it the host leaves that table in bypass, so the WCN6855 endpoint hits
# the apps SMMU on a stream with no context bank and the first host-memory DMA
# (amss.bin downloaded, copy-engine rings live) is aborted - the silent reset of
# A122-A124, A127-A129.
# set -e
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
A=/tmp/y700
cd "$K" || exit 1
cmp -s "$B/unpin_next.txt" "$B/unpin_next.a115.txt" || { echo A130_UNPIN_SET_MOVED; sha256sum "$B/unpin_next.txt" "$B/unpin_next.a115.txt"; exit 1; }
cp -f "$B/a1.dtb" "$B/a1.dtb.a128.keep" 2>/dev/null || true
export Y700_EXTRA_DISABLE=displayport-controller@ae90000 Y700_APPS_SMMU=1 Y700_A70=1 Y700_A102=1 Y700_GPU=1
Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" > "$A/a130-dtb.log" 2>&1 || { echo A130_DTB_GEN_FAIL; tail -40 "$A/a130-dtb.log"; exit 1; }
grep -iE "iommu|strip" "$A/a130-dtb.log" | head -8
[ -s "$B/a1.dtb" ] || { echo A130_NO_DTB; exit 1; }
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a130.dts" || { echo A130_DTC_FAIL; exit 1; }
grep -q 'iommu-map = <0x00 0x44 0x1c00 0x00 0x01 0x100 0x44 0x1c01 0x00 0x01>;' "$B/chk_a130.dts" || { echo A130_PCIE0_IOMMU_MAP_MISSING; grep -n "iommu-map" "$B/chk_a130.dts" | head; exit 1; }
grep -q 'iommu-map = <0x00 0x44 0x1c80 0x00 0x01 0x100 0x44 0x1c81 0x00 0x01>;' "$B/chk_a130.dts" || { echo A130_PCIE1_IOMMU_MAP_MISSING; grep -n "iommu-map" "$B/chk_a130.dts" | head; exit 1; }
nmap=$(grep -c "iommu-map = <" "$B/chk_a130.dts")
echo "iommu-map lines in the new DTB: $nmap"
[ "$nmap" = 2 ] || { echo A130_IOMMU_MAP_COUNT; exit 1; }
if grep -q "iommu-map = <" "$B/chk_a115.dts" ; then echo A130_BASELINE_ALREADY_HAS_MAP; exit 1; fi
diff "$B/chk_a115.dts" "$B/chk_a130.dts" > "$A/a130-dts-diff.txt" || true
added=$(grep -c "^>" "$A/a130-dts-diff.txt")
removed=$(grep -c "^<" "$A/a130-dts-diff.txt")
echo "dts delta vs a115: added=$added removed=$removed"
[ "$removed" = 0 ] || { echo A130_DTS_LOST_LINES; grep "^<" "$A/a130-dts-diff.txt" | head -20; exit 1; }
[ "$added" = 2 ] || { echo A130_DTS_DELTA_NOT_TWO; cat "$A/a130-dts-diff.txt"; exit 1; }
[ "$(grep -c "^>.*iommu-map" "$A/a130-dts-diff.txt")" = 2 ] || { echo A130_DTS_DELTA_NOT_IOMMU_MAP; exit 1; }
export Y700_GPU=1 Y700_APPS_SMMU=1 Y700_A70=1 Y700_A102=1 Y700_MINIMAL=1
python3 "$B/chk_minimal.py" "$B/chk_a130.dts" || { echo A130_CHK_MINIMAL_FAIL; exit 1; }
[ -s "$B/a1.dtb.a130" ] || cp -f "$B/a1.dtb" "$B/a1.dtb.a130"
cmp -s "$B/a1.dtb" "$B/a1.dtb.a130" || { echo A130_DTB_NOT_PINNED; sha256sum "$B/a1.dtb" "$B/a1.dtb.a130"; exit 1; }
ls -l "$B/a1.dtb" "$B/a1.dtb.a115" "$B/a1.dtb.a130"
sha256sum "$B/a1.dtb" "$B/a1.dtb.a130" "$B/a1.dtb.a115"
echo A130_DTB_OK
