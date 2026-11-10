#!/bin/bash
# A96 = A94 + the applications SMMU, so the DPU can bind at all.
#
# A94 proved the display chain binds (mdss/dpu/dsi0/dsi1/both PHYs all probed,
# ktz8866 backlight up, touch up) and then died inside msm:
#   msm_dpu ae01000.display-controller: [drm] no IOMMU, bailing out
#   [dpu error]dpu_kms_mmu_init failed: -19  ->  kms hw init failed
#   Oops in drm_atomic_private_obj_fini (double _dpu_kms_hw_destroy)
#   -> the deferred_probe worker died, so ufshc never probed and UFS vanished.
# msm_kms_init_vm() has no non-IOMMU path: mainline DPU needs a real SMMU.
#
# A96 changes two things and nothing else:
#  1. kernel: patch_a96.py makes dpu_kms_global_obj_fini() idempotent, so a DPU
#     failure degrades to "no card" instead of taking the deferred queue (and
#     with it UFS/the UFS root) down with it.
#  2. DTB: Y700_APPS_SMMU=1 leaves iommu@15000000 (qcom,sm8450-smmu-500) enabled
#     and keeps the iommus/iommu-map bindings that point at it, while the refs to
#     the still-off gpu SMMU (iommu@3da0000) stay stripped.  Half of this is not
#     optional: arm-smmu turns off every context bank ABL programmed, so ufshc
#     and mmc only keep working DMA once Linux programs a context bank for them.
# Rollback is one fastboot flash away: .work/boot-b-a88.img (sha 77aa2960...).
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
echo "=== a96 build start $(date -u) ==="

grep -q 'CONFIG_ARM_SMMU=y' .config || { echo A96_SMMU_CFG_LOST; exit 1; }
grep -q 'CONFIG_ARM_SMMU_QCOM=y' .config || { echo A96_SMMU_QCOM_CFG_LOST; exit 1; }
grep -q 'CONFIG_IOMMU_DMA=y' .config || { echo A96_IOMMU_DMA_CFG_LOST; exit 1; }
grep -q 'CONFIG_DRM_MSM_DPU=y' .config || { echo A96_DPU_CFG_LOST; exit 1; }
grep -q 'CONFIG_DRM_SIMPLEDRM=y' .config || { echo A96_SIMPLEDRM_LOST; exit 1; }
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo A96_INITRAMFS_CFG_MOVED; exit 1; }
[ -s "$B/out/boot-b-a88.img" ] || { echo NO_A88_ROLLBACK_IMAGE; exit 1; }
nm vmlinux | grep -q ' arm_smmu_device_probe' || { echo A96_SMMU_NOT_BUILT_IN; exit 1; }

python3 /tmp/y700/kbuild/patch_a96.py || { echo PATCH_A96_FAIL; exit 1; }
grep -q 'global state already finalized' drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c || { echo A96_PATCH_MISSING; exit 1; }

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image || { echo A96_MAKE_FAIL; exit 1; }
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
sha256sum arch/arm64/boot/Image "$B/armada-boot/vmlinuz"
strings vmlinux | grep -q 'global state already finalized' || { echo A96_FIX_NOT_IN_VMLINUX; exit 1; }
nm vmlinux | grep -q ' disp_cc_sm8450_driver_init' || { echo A96_DISPCC_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q ' nt36523_driver_init' || { echo A96_PANEL_DRIVER_NOT_BUILT_IN; exit 1; }
nm vmlinux | grep -q ' msm_kms_init_vm' || { echo A96_KMS_VM_SYM_LOST; exit 1; }

# keep the A94 DTB so the delta of this round is auditable
cp -f "$B/a1.dtb" "$B/a1.dtb.a94" || exit 1
cp -f "$B/a1.dts" "$B/a1.dts.a94" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb.a94" > "$B/chk_a94.dts" || { echo DTC_A94_FAIL; exit 1; }

export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
export Y700_APPS_SMMU=1
unset Y700_A65_BL_OFF
export Y700_A70=1
dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; printf '%s\n' "$dtbout"; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A70: y700-stub-panel added' || { echo A70_STEP_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'iommu consumer properties removed: [0-9]*, kept for iommu@15000000: [0-9][0-9]' || { echo A96_IOMMU_REFS_NOT_KEPT; exit 1; }

"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a96.dts" || { echo DTC_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a96.dts" || { echo CHK_FAIL; exit 1; }

python3 - "$B/chk_a96.dts" <<PYCHK || { echo A96_DTB_GATE_FAIL; exit 1; }
import re, sys
must_on = ['display-subsystem@ae00000', 'display-controller@ae01000',
           'dsi@ae94000', 'dsi@ae96000', 'phy@ae94400', 'phy@ae96400',
           'clock-controller@af00000', 'backlight@11', 'iommu@15000000',
           'ufshc@1d84000', 'mmc@8804000']
must_off = ['displayport-controller@ae90000', 'iommu@3da0000',
            'gpu@3d00000', 'gmu@3d6a000', 'video-codec@aa00000']
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


def find(name):
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            return i
    return None


bad = 0
for n in must_on + must_off:
    i = find(n)
    if i is None:
        print('BAD  %-34s MISSING' % n)
        bad += 1
        continue
    st = 'ok'
    for p in own(i):
        m = re.match(r'status = "([^"]*)";', p)
        if m:
            st = m.group(1)
    want_off = n in must_off
    ok = (st == 'disabled') if want_off else (st != 'disabled')
    bad += 0 if ok else 1
    print('%-4s %-5s %-34s %s' % ('OK' if ok else 'BAD', 'OFF' if want_off else 'ON', n, st))

# the apps SMMU phandle is 0x44 in this board DT; every live master must point at it
smmu_i = find('iommu@15000000')
ph = [p for p in own(smmu_i) if p.startswith('phandle = ')][0].split('<')[1].split('>')[0]
# upstream sm8450 puts the display stream on the MDSS node, not on the mdp
# child: msm_kms_init_vm() falls back to dev->dev->parent, i.e. mdss.
for n in ['display-subsystem@ae00000', 'ufshc@1d84000', 'mmc@8804000',
          'usb@a600000']:
    props = [p for p in own(find(n)) if p.startswith('iommus = <')]
    ok = len(props) == 1 and all(ph in p for p in props)
    bad += 0 if ok else 1
    print('%-4s iommus %-28s %s' % ('OK' if ok else 'BAD', n, props))
stray = [ln.strip() for ln in lines if ln.strip().startswith('iommus = <') and ph not in ln]
print('%-4s iommus not pointing at %s: %d %s' % ('OK' if not stray else 'BAD', ph, len(stray), stray[:4]))
bad += len(stray)
sys.exit(1 if bad else 0)
PYCHK

echo "=== A96 dtb delta vs A94 (first 60 lines) ==="
diff "$B/chk_a94.dts" "$B/chk_a96.dts" | head -60
diff "$B/chk_a94.dts" "$B/chk_a96.dts" | grep -c '^<' || true

cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1

python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a96.img" || { echo PACK_FAIL; exit 1; }

strings "$B/out/boot-b-a96.img" | grep -q 'global state already finalized' || { echo A96_IMAGE_IS_STALE; exit 1; }
strings "$B/out/boot-b-a96.img" | grep -q 'no IOMMU, bailing out' || { echo A96_MSM_KMS_LOST; exit 1; }
strings "$B/out/boot-b-a96.img" | grep -q 'qcom,sm8450-smmu-500' || { echo A96_SMMU_MATCH_LOST; exit 1; }
strings "$B/out/boot-b-a96.img" | grep -q 'lenovo,y700-nt36523n' || { echo A96_PANEL_NOT_IN_IMAGE; exit 1; }
cp -f "$B/out/boot-b-a96.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a96.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a96.img /root/y700-artifacts/boot-b-a96.img
sha256sum /tmp/y700/e15/boot-b-a96.img
echo "=== a96 end $(date -u) ==="
echo A96_ALL_OK
