#!/bin/bash
# A102 = A96 + the touch follower hung off the real DSI panel.  DTB only.
#
# A96 dmesg has the whole failure in nine milliseconds:
#   2.191252  Y700-STUB panel registered prepared=1 enabled=1
#   3.164655  novatek-nt36523n-spi spi0.0: finger input ready
#   3.173793  Y700-PROBE ae94000.dsi.0 panel-novatek-nt36523
#   3.943829  probe of ae94000.dsi.0 ... returned 0 after 770037 usecs
# The A70 stub panel released the follower at boot+2.19 s, so the driver
# uploaded the 196608-byte touch firmware and enabled INT 21 - and then the
# real panel driver probed, asserted its reset line (devm_gpiod_get(...,
# GPIOD_OUT_HIGH)) and ran a 770 ms DSI init over the same NT36523 silicon.
# That is why /proc/interrupts shows "131: 0 ... msmgpio 21 Edge spi0.0"
# forever: the chip lost the firmware image, it never drives INT again, and
# userspace sees a perfectly well-tagged touchscreen that has nothing to say.
#
# A102 changes exactly one property: touchscreen@0 `panel` goes from the stub
# (0x7f00) to the real panel@0 the DSI driver registers.  find_panel_by_fwnode()
# then defers the SPI client until that panel exists, and
# drm_panel_add_follower()/panel_prepared() do the firmware upload after the
# panel came up instead of 770 ms before it.  The stub node stays registered
# with nobody following it, so the kernel delta is nothing at all.
#
# Rollback is one fastboot flash away: .work/boot-b-a96.img (sha f728a6ed...).
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
echo "=== a102 build start $(date -u) ==="

[ -s "$B/out/boot-b-a96.img" ] || { echo NO_A96_ROLLBACK_IMAGE; exit 1; }
[ -s "$B/armada-boot/vmlinuz" ] || { echo NO_A96_KERNEL; exit 1; }
# only the DTB may move this round, so the kernel has to be byte-identical
cmp -s arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || { echo KERNEL_CHANGED; exit 1; }
grep -q 'NT36523=y' .config || { echo NT36523_CFG_LOST; exit 1; }
nm vmlinux | grep -q ' nvt_nt36523n_probe' || { echo TOUCH_DRIVER_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q ' nt36523_driver_init' || { echo PANEL_DRIVER_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q ' y700_stub_probe' || { echo STUB_DRIVER_NOT_BUILT_IN; exit 1; }

# keep the A96 DTB so the delta of this round is auditable
cp -f "$B/a1.dtb" "$B/a1.dtb.a96" || exit 1
cp -f "$B/a1.dts" "$B/a1.dts.a96" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb.a96" > "$B/chk_a96.dts" || { echo DTC_A96_FAIL; exit 1; }

export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
export Y700_APPS_SMMU=1
unset Y700_A65_BL_OFF
export Y700_A70=1
export Y700_A102=1
dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; printf '%s\n' "$dtbout"; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A70: y700-stub-panel added' || { echo A70_STEP_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A102: touchscreen@0 panel -> ' || { echo A102_STEP_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'iommu consumer properties removed: [0-9]*, kept for iommu@15000000: [0-9][0-9]' || { echo A96_IOMMU_REFS_NOT_KEPT; exit 1; }

"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a102.dts" || { echo DTC_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a102.dts" || { echo CHK_FAIL; exit 1; }

echo "=== A102 dtb delta vs A96 ==="
diff "$B/chk_a96.dts" "$B/chk_a102.dts" || true

python3 - "$B/chk_a96.dts" "$B/chk_a102.dts" <<'PYGATE' || { echo A102_DTB_GATE_FAIL; exit 1; }
import re, sys

def own(lines, hdr):
    ind = lines[hdr][:len(lines[hdr]) - len(lines[hdr].lstrip())]
    end = lines.index(ind + '};', hdr + 1)
    depth, props = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip():
            props.append(lines[k].strip())
        depth += lines[k].count('{') - lines[k].count('}')
    return props


def find(lines, name):
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            return i
    raise AssertionError('missing node: %s' % name)


a = open(sys.argv[1], encoding='utf-8').read().split('\n')
b = open(sys.argv[2], encoding='utf-8').read().split('\n')
assert len(a) == len(b), 'dtb delta changed the line count: %d vs %d' % (len(a), len(b))
diff = [i for i in range(len(a)) if a[i] != b[i]]
print('changed lines: %d %s' % (len(diff), [(i + 1, a[i].strip(), b[i].strip()) for i in diff]))
assert len(diff) == 1, 'A102 must change exactly one line, changed %d' % len(diff)
assert 'panel = <' in a[diff[0]] and a[diff[0]].strip() == 'panel = <0x7f00>;'
assert 'panel = <' in b[diff[0]], 'the one change is not the panel property'

ph = [p for p in own(b, find(b, 'panel@0')) if p.startswith('phandle = ')][0]
ph = ph.split('<')[1].split('>')[0]
tp = [p for p in own(b, find(b, 'touchscreen@0')) if p.startswith('panel = <')][0]
print('panel@0 phandle=%s  touchscreen@0 %s' % (ph, tp))
assert tp.strip() == 'panel = <%s>;' % ph, 'touchscreen@0 does not point at panel@0'
assert 'panel = <0x7f00>;' not in '\n'.join(b), 'the stub is still referenced'
stub = [p for p in own(b, find(b, 'y700-stub-panel'))]
print('stub node kept, inert: %s' % stub)
PYGATE

cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a102.img" || { echo PACK_FAIL; exit 1; }

python3 - "$B/out/boot-b-a102.img" "$B/a1.dtb" <<'PYIMG' || { echo A102_DTb_NOT_IN_IMAGE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('boot image %d bytes, a1.dtb %d bytes, found at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYIMG
strings "$B/out/boot-b-a102.img" | grep -q 'finger input ready' || { echo TOUCH_DRIVER_LOST; exit 1; }
strings "$B/out/boot-b-a102.img" | grep -q 'lenovo,y700-nt36523n' || { echo PANEL_MATCH_LOST; exit 1; }
strings "$B/out/boot-b-a102.img" | grep -q 'global state already finalized' || { echo A96_KERNEL_FIX_LOST; exit 1; }

cp -f "$B/out/boot-b-a102.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a102.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a102.img /root/y700-artifacts/boot-b-a102.img
sha256sum /tmp/y700/e15/boot-b-a102.img
echo "=== a102 end $(date -u) ==="
echo A102_ALL_OK
