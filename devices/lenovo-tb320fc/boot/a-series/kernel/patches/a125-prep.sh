#!/bin/bash
# A125 prep: the Wi-Fi round - put the DTB back to the A115 bytes (pcie0 + phy okay).
#
# A115 unpinned pcie@1c00000 / phy@1c06000 by appending those names to
# $B/unpin_next.txt and re-running mk_a1_dtb.py; A116-A118 deliberately parked that
# state (a1.dtb.a115 + unpin_next.a115.txt) and ran with the A114 bytes while the
# touch stack was chased.  The touch stack is fixed now, so the unpin list goes back
# in and the regenerated DTB has to be byte-identical to what A115 produced.
#
# mk_a1_dtb.py also writes a1.dtb.info (placeholder_off), so regeneration - not a
# hand copy - is the only correct way to get both files.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
[ -s "$B/a1.dtb.a115" ] || { echo NO_A115_DTB; exit 1; }
[ -s "$B/unpin_next.a115.txt" ] || { echo NO_A115_UNPIN_LIST; exit 1; }
# keep the A114 pair recoverable, then make the unpin list the A115 one again
cp -f "$B/a1.dtb.a114" "$B/a1.dtb.a114.keep" 2>/dev/null
[ -s "$B/unpin_next.a114.txt" ] || grep -vx 'pcie@1c00000\|phy@1c06000' "$B/unpin_next.a115.txt" > "$B/unpin_next.a114.txt"
cp -f "$B/unpin_next.a115.txt" "$B/unpin_next.txt" || exit 1
echo "unpin_next entries=$(grep -c . "$B/unpin_next.txt") a114_entries=$(grep -c . "$B/unpin_next.a114.txt") pcie_present=$(grep -c 'pcie@1c00000' "$B/unpin_next.txt")"
sha256sum "$B/a1.dtb" "$B/a1.dtb.a114" "$B/a1.dtb.a115" 2>&1
export Y700_EXTRA_DISABLE='displayport-controller@ae90000' Y700_APPS_SMMU=1 Y700_A70=1 Y700_A102=1 Y700_GPU=1
Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" > /tmp/y700/a125-dtb.log 2>&1 || { echo DTB_REGEN_FAIL; tail -30 /tmp/y700/a125-dtb.log; exit 1; }
tail -8 /tmp/y700/a125-dtb.log
cat "$B/a1.dtb.info"
cmp -s "$B/a1.dtb" "$B/a1.dtb.a115" || { echo REGENERATED_DTB_DIFFERS_FROM_A115; sha256sum "$B/a1.dtb" "$B/a1.dtb.a115"; exit 1; }
echo "the regenerated DTB is byte-identical to a1.dtb.a115"
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a125.dts" || { echo DTC_FAIL; exit 1; }
echo "dts diff vs A114 lines=$(diff "$B/chk_a114.dts" "$B/chk_a125.dts" | grep -c .)"
diff "$B/chk_a114.dts" "$B/chk_a125.dts" | head -20
echo okay_nodes=$(grep -c 'status = "okay"' "$B/chk_a125.dts")
# the awk range in earlier rounds stopped at the phy node's own header line, so it
# counted one status too few; read each node's status explicitly instead.
python3 - "$B/chk_a125.dts" <<'PYNODE' || exit 1
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
bad = 0
for name in ("pcie@1c00000", "phy@1c06000"):
    m = re.search(re.escape(name) + r"\s*\{(.*?)\n\t\t\};", t, re.S)
    if not m:
        print("NODE_MISSING " + name); bad = 1; continue
    st = re.search(r'status = "([a-z]+)"', m.group(1))
    v = st.group(1) if st else "absent(=okay)"
    print("node %s status=%s" % (name, v))
    if v not in ("okay", "absent(=okay)"):
        bad = 1
print("wcn_endpoint=%d wcn_pmu=%d" % (t.count("pci17cb,1103"), t.count("qcom,wcn6855-pmu")))
sys.exit(1 if bad else 0)
PYNODE
[ $? -eq 0 ] || { echo PCIE0_STILL_PINNED; exit 1; }
N=$(diff "$B/chk_a114.dts" "$B/chk_a125.dts" | grep -c '^> .*status = "okay";')
echo flipped_to_okay=$N
[ "$N" -eq 2 ] || { echo UNPIN_FLIP_COUNT_WRONG; exit 1; }
# ---- A125: the ath11k firmware A122 baked in goes back out ----
# +4.3 MiB in the initramfs grew the embedded Image 0x36dca00 -> 0x396ca00 and every
# boot since died before the SD card was even probed - including A124 with
# ath11k_pci_init blacklisted, so it was not the driver.  Revert that variable.
IR=/tmp/y700/initramfs
rm -rf "$IR/lib/firmware/ath11k" || exit 1
[ -d "$IR/lib/firmware/ath11k" ] && { echo ATH11K_FW_STILL_PRESENT; exit 1; }
for f in qcom/a730_sqe.fw qcom/gmu_gen70000.bin qcom/sm8475/lenovo/tb320fc/a730_zap.mdt novatek/lenovo-tb320fc.bin; do
	[ -s "$IR/lib/firmware/$f" ] || { echo "TOUCH_GPU_FW_LOST $f"; exit 1; }
done
echo "initramfs firmware dir=[$(ls "$IR/lib/firmware" | tr '\n' ',')] size=$(du -sk "$IR" | cut -f1)K"
echo A125_NO_FW_OK
echo A125_PREP_OK
