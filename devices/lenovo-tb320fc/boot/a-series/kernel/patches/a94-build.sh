#!/bin/bash
# A94 = A88 with the display chain handed back to Linux.
#
# What A88 ships: every MDSS node is status="disabled", the panel keeps running
# on ABL's setup and Linux only paints into ABL's framebuffer (simpledrm over
# /chosen/framebuffer).  That gave us weston, but no real KMS, no panel init,
# no mode/rotation from the panel and no way to a GPU.
#
# A94 is a DTB-only change - the Image, the initramfs and the cmdline stay as
# A88 left them, so a failure is one fastboot flash away from boot-b-a88.img:
#  * mdss / dpu / dsi0 / dsi1 / both DSI PHYs / dispcc come back.  The node
#    sweep already promoted all of them into a1/unpin_next.txt, and the board
#    DTS is a complete description: dual-DSI C-PHY with cphy-timing,
#    vdda(pm8350_l9)/vdds(pm8350_l5)/vddio(pm8350c_l12), reset-gpios 0, and
#    panel@0 "lenovo,y700-nt36523n" -> drivers/gpu/drm/panel/panel-novatek-nt36523.c
#    (459 vendor on-commands, mipi_dsi_dual_dcs_write_seq_multi) plus the
#    "lenovo,y700-ktz8866" backlight that A92 already proved we can dim.
#  * displayport-controller@ae90000 stays pinned off (A50: msm-dp-display fails
#    probe with -ENODEV on this pad, and a component that never binds blocks the
#    DPU master forever, so no card is ever created).
#  * iommu@15000000 (apps_smmu) stays pinned off and every iommus property is
#    still stripped.  arm-smmu installs its own stream table at probe and aborts
#    every stream it was not asked to translate - that is the A47/A54 black
#    screen, and it would abort UFS too.  Left alone, ABL keeps the streams
#    bypassed, so the DPU DMAs to physical addresses.
#  * CONFIG_DRM_SIMPLEDRM stays on: if the DPU does not bind, the panel keeps
#    the A88 behaviour (console + weston on the splash fb) instead of going dark.
#  * Y700_A70=1 keeps the stub panel as the touchscreen's drm_panel parent, so
#    the touch driver cannot sit in -EPROBE_DEFER because of this change.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
echo "=== a94 build start $(date -u) ==="

grep -q 'CONFIG_DRM_MSM_DPU=y' .config || { echo A94_DPU_CFG_LOST; exit 1; }
grep -q 'CONFIG_DRM_MSM_DSI_7NM_PHY=y' .config || { echo A94_DSI_PHY_CFG_LOST; exit 1; }
grep -q 'CONFIG_DRM_PANEL_NOVATEK_NT36523=y' .config || { echo A94_PANEL_CFG_LOST; exit 1; }
grep -q 'CONFIG_BACKLIGHT_KTZ8866=y' .config || { echo A94_BL_CFG_LOST; exit 1; }
grep -q 'CONFIG_QCOM_RPMHPD=y' .config || { echo A94_RPMHPD_LOST; exit 1; }
grep -q 'CONFIG_INTERCONNECT_QCOM_SM8450=y' .config || { echo A94_ICC_CFG_LOST; exit 1; }
grep -q 'CONFIG_DRM_SIMPLEDRM=y' .config || { echo A94_SIMPLEDRM_LOST; exit 1; }
grep -q 'CONFIG_DRM_MSM_KMS_FBDEV=y' .config || { echo A94_MSM_FBDEV_LOST; exit 1; }
[ -s "$B/armada-boot/vmlinuz" ] || { echo NO_VMLINUZ; exit 1; }
[ -s "$B/out/boot-b-a88.img" ] || { echo NO_A88_ROLLBACK_IMAGE; exit 1; }
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }

# dispcc must be in vmlinux - MDSS_GDSC and every MDSS clock hangs off it.
nm vmlinux | grep -q 'disp_cc_sm8450_driver_init' || { echo A94_DISPCC_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q 'nt36523_driver_init' || { echo A94_PANEL_DRIVER_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q 'ktz8866_driver_init' || { echo A94_BL_DRIVER_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q 'dpu_kms_hw_init' || { echo A94_DPU_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q 'rpmhpd' || { echo A94_RPMHPD_SYM_LOST; exit 1; }

# keep the A88 DTB so the diff of this round is auditable
cp -f "$B/a1.dtb" "$B/a1.dtb.a88" || exit 1
cp -f "$B/a1.dts" "$B/a1.dts.a88" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb.a88" > "$B/chk_a88.dts" || { echo DTC_A88_FAIL; exit 1; }

export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
unset Y700_A65_BL_OFF
export Y700_A70=1
dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; printf '%s\n' "$dtbout"; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A70: y700-stub-panel added' || { echo A70_STEP_MISSING; exit 1; }

"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a94.dts" || { echo DTC_FAIL; exit 1; }
Y700_EXTRA_DISABLE="$Y700_EXTRA_DISABLE" python3 "$B/chk_minimal.py" "$B/chk_a94.dts" || { echo CHK_FAIL; exit 1; }

python3 - "$B/chk_a94.dts" <<'PYCHK' || { echo A94_DTB_GATE_FAIL; exit 1; }
import re, sys
must_on = ['display-subsystem@ae00000', 'display-controller@ae01000',
           'dsi@ae94000', 'dsi@ae96000', 'phy@ae94400', 'phy@ae96400',
           'clock-controller@af00000', 'backlight@11']
must_off = ['displayport-controller@ae90000', 'iommu@15000000',
            'iommu@3da0000', 'gpu@3d00000', 'video-codec@aa00000']
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')


def own(hdr):
    ind = lines[hdr][:len(lines[hdr]) - len(lines[hdr].lstrip())]
    end = lines.index(ind + '};', hdr + 1)
    depth, props = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip():
            props.append(lines[k].strip())
        depth += lines[k].count('{') - lines[k].count('}')
    return props


def status_of(name):
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            for p in own(i):
                m = re.match(r'status = "([^"]*)";', p)
                if m:
                    return m.group(1)
            return 'ok'
    return None


bad = 0
for n in must_on:
    got = status_of(n)
    ok = got not in (None, 'disabled')
    bad += 0 if ok else 1
    print('%-4s ON   %-32s %s' % ('OK' if ok else 'BAD', n, got))
for n in must_off:
    got = status_of(n)
    ok = got == 'disabled'
    bad += 0 if ok else 1
    print('%-4s OFF  %-32s %s' % ('OK' if ok else 'BAD', n, got))
print('iommus properties left in the tree: %d (must be 0)'
      % len([1 for ln in lines if ln.strip().startswith('iommus = ')]))
sys.exit(1 if bad else 0)
PYCHK

echo "=== A94 dtb delta vs A88 (status lines) ==="
diff "$B/chk_a88.dts" "$B/chk_a94.dts" | grep -E 'status|^[0-9]' | head -40
diff "$B/chk_a88.dts" "$B/chk_a94.dts" | grep -c '^<' || true

cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1

python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a94.img" || { echo PACK_FAIL; exit 1; }

# the packed image must carry the kernel A88 built and the DTB A94 just wrote
strings "$B/out/boot-b-a94.img" | grep -q 'panel claimed by simpledrm' || { echo A94_IMAGE_IS_STALE; exit 1; }
strings "$B/out/boot-b-a94.img" | grep -q 'lenovo,y700-nt36523n' || { echo A94_PANEL_NOT_IN_IMAGE; exit 1; }
strings "$B/out/boot-b-a94.img" | grep -q 'qcom,sm8450-dpu' || { echo A94_DPU_NOT_IN_IMAGE; exit 1; }
strings "$B/out/boot-b-a94.img" | grep -q 'qcom,sm8450-mdss' || { echo A94_MDSS_NOT_IN_IMAGE; exit 1; }
strings "$B/out/boot-b-a94.img" | grep -q 'selinux=0' || { echo CMDLINE_NOT_IN_IMAGE; exit 1; }
cp -f "$B/out/boot-b-a94.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a94.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a94.img /root/y700-artifacts/boot-b-a94.img
sha256sum /tmp/y700/e15/boot-b-a94.img
echo "=== a94 end $(date -u) ==="
echo A94_ALL_OK