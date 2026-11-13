#!/bin/bash
# A104 = A102 + the Adreno 730 stack.  Kernel binary moves only because the
# GPU firmware goes into the initramfs; the DTB un-pins four nodes.
#
# Why the firmware has to be in the initramfs and not just in the rootfs:
# drivers/gpu/drm/msm/adreno/adreno_gpu.c adreno_zap_shader_load() answers
# -ENOENT when the zap MDT cannot be requested, and a6xx_gpu.c treats anything
# except -ENODEV as fatal (a6xx_gpu_init:1520 `return ret`).  The GPU is a
# component of the msm master, so a GPU probe that fails with -ENOENT leaves
# component_bind_all() unfinished - and the display card we already have would
# disappear with it.  Probe runs at of_platform_populate() time, i.e. while the
# initramfs is still the root, exactly like the 196608-byte touch image that
# already lives there.  /usr/lib/firmware in the UFS root only holds *.xz names
# (linux-firmware is stored compressed in the Armada image), so request_firmware
# would miss even the generic a730_sqe.fw.
#
# What the DT carries for the GPU (base_a1.dts, all four nodes pinned off by
# A1m and their iommus bindings removed by A96):
#   gpu@3d00000            qcom,adreno-730.1, iommus = <&adreno_smmu 0x0 0x400
#                          &adreno_smmu 0x1 0x400>, zap-shader child with
#                          memory-region = <&gpu_micro_code_mem> and
#                          firmware-name = qcom/sm8475/lenovo/tb320fc/a730_zap.mdt
#   gmu@3d6a000            gmu+rscc+gmu_pdc regs, power-domains = <&gpucc cx gx>,
#                          iommus = <&adreno_smmu 0x5 0x400>, qcom,qmp = <&aoss_qmp>
#   clock-controller@3d90000  gpucc, #clock-cells/#power-domain-cells
#   iommu@3da0000          the adreno SMMU (its own master-side SMMU)
# aoss-qmp stays pinned off: a6xx_gmu.c:2032 only needs it when ACD is enabled,
# everything else is guarded by IS_ERR_OR_NULL(gmu->qmp).
#
# Rollback is one fastboot flash away: /tmp/y700/e15/boot-b-a102.img
# (sha 9051b38da1c56ded58c128c5118a76a90a1e3829eda7ab13c89f1a51213ae2e5).
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
IR=/tmp/y700/initramfs
FW=/tmp/y700/fw-asphalt/lenovo/tb320fc/firmware
cd "$K" || exit 1
echo "=== a104 build start $(date -u) ==="

[ -s /tmp/y700/e15/boot-b-a102.img ] || { echo NO_A102_ROLLBACK_IMAGE; exit 1; }
[ -s "$B/armada-boot/vmlinuz" ] || { echo NO_A102_KERNEL; exit 1; }
# keep a pristine copy of the kernel the board runs today, so a re-run of this
# script can tell "already rebuilt" from "the tree moved on its own"
[ -s "$B/armada-boot/vmlinuz.a102" ] || cp -f "$B/armada-boot/vmlinuz" "$B/armada-boot/vmlinuz.a102"
[ -s "$B/armada-boot/vmlinuz.a102" ] || { echo NO_A102_KERNEL_COPY; exit 1; }
sha256sum "$B/armada-boot/vmlinuz.a102" arch/arm64/boot/Image

# ---- GPU stack must already be built into the running kernel ----
nm vmlinux | grep -qE ' D a7xx_gpulist$' || { echo GPU_CATALOG_NOT_BUILT; exit 1; }
nm vmlinux | grep -qE ' D a7xx_gpu_funcs$' || { echo GPU_FUNCS_NOT_BUILT; exit 1; }
nm vmlinux | grep -qE ' T adreno_zap_shader_load$' || { echo ZAP_LOADER_NOT_BUILT; exit 1; }
nm vmlinux | grep -qE ' T qcom_pas_is_available$' || { echo PAS_NOT_BUILT; exit 1; }
grep -q 'CONFIG_QCOM_SCM=y' .config || { echo QCOM_SCM_OFF; exit 1; }
grep -q 'CONFIG_QCOM_PAS=y' .config || { echo QCOM_PAS_OFF; exit 1; }
grep -q 'CONFIG_ARM_SMMU=y' .config || { echo ARM_SMMU_OFF; exit 1; }
grep -q 'CONFIG_ARM_SMMU_QCOM=y' .config || { echo ARM_SMMU_QCOM_OFF; exit 1; }
grep -q 'CONFIG_DRM_MSM_DPU=y' .config || { echo MDSS_OFF; exit 1; }
# nothing that already works may regress
grep -q 'NT36523=y' .config || { echo NT36523_CFG_LOST; exit 1; }
grep -q 'CONFIG_FRAMEBUFFER_CONSOLE=y' .config || { echo FBCON_LOST; exit 1; }
# snapshot the running kernel (only on the first pass - after the rebuild the
# tree holds the new one)
[ -s "$B/nm-a102.txt" ] || nm "$B/armada-boot/vmlinuz.a102" | awk '{print $2, $3}' | sort > "$B/nm-a102.txt"
[ -s "$B/nm-a102.txt" ] || { echo NM_A102_FAIL; exit 1; }
wc -l "$B/nm-a102.txt"
# and its human-readable strings, junk from the embedded cpio filtered out
# the kernel version string changes with every link (#76 -> #77), everything
# else in the read-only data has to be byte-for-byte the same as yesterday
strg() { strings "$1" | grep -E '[A-Za-z]{4}[A-Za-z0-9_ ,.:;%()/*+=<>-]{10,}' | grep -v 'SMP PREEMPT' | sort -u; }
[ -s "$B/strings-a102.txt" ] || strg "$B/armada-boot/vmlinuz.a102" > "$B/strings-a102.txt"
[ -s "$B/strings-a102.txt" ] || { echo STRINGS_A102_FAIL; exit 1; }
wc -l "$B/strings-a102.txt"

# ---- the six GPU firmware blobs into the initramfs ----
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }
mkdir -p "$IR/lib/firmware/qcom" "$IR/lib/firmware/qcom/sm8475/lenovo/tb320fc" || exit 1
cp -f "$FW/a730_sqe.fw"        "$IR/lib/firmware/qcom/a730_sqe.fw"        || exit 1
cp -f "$FW/gmu_gen70000.bin"   "$IR/lib/firmware/qcom/gmu_gen70000.bin"   || exit 1
for f in a730_zap.mdt a730_zap.b00 a730_zap.b01 a730_zap.b02; do
	cp -f "$FW/$f" "$IR/lib/firmware/qcom/sm8475/lenovo/tb320fc/$f" || exit 1
done
for spec in qcom/a730_sqe.fw:74676 qcom/gmu_gen70000.bin:57272 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.mdt:4044 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.b00:148 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.b01:2236 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.b02:3896; do
	p=${spec%%:*}; want=${spec##*:}
	got=$(wc -c < "$IR/lib/firmware/$p" 2>/dev/null)
	[ "$got" = "$want" ] || { echo "FW_SIZE_MISMATCH $p got=$got want=$want"; exit 1; }
	echo "fw in initramfs $p $got"
done

# ---- rebuild: only the initramfs cpio changes, the C code does not ----
if [ -s "$B/a104-kernel.img" ]; then
	echo RESUME_KERNEL_ALREADY_REBUILT
	cmp -s arch/arm64/boot/Image "$B/a104-kernel.img" || { echo KERNEL_TREE_DIRTY; exit 1; }
else
	rm -f usr/initramfs_data.cpio usr/initramfs_data.o
	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image > /tmp/y700/kbuild/a104-make.log 2>&1 || { echo MAKE_FAIL; tail -40 /tmp/y700/kbuild/a104-make.log; exit 1; }
	cp -f arch/arm64/boot/Image "$B/a104-kernel.img" || exit 1
fi
tail -12 /tmp/y700/kbuild/a104-make.log
for n in a730_sqe.fw gmu_gen70000.bin a730_zap.mdt a730_zap.b02; do
	c=$(grep -c "$n" usr/initramfs_data.cpio)
	[ "$c" -ge 1 ] || { echo "FW_NOT_IN_CPIO $n"; exit 1; }
	echo "cpio contains $n ($c)"
done
# the symbol set must be identical - same code, bigger initramfs
nm vmlinux | awk '{print $2, $3}' | sort > "$B/nm-a104.txt" || { echo NM_A104_FAIL; exit 1; }
diff "$B/nm-a102.txt" "$B/nm-a104.txt" > /tmp/y700/kbuild/a104-nm-diff.txt || { echo A104_SYMBOL_DELTA; cat /tmp/y700/kbuild/a104-nm-diff.txt; exit 1; }
wc -l "$B/nm-a104.txt"
strg arch/arm64/boot/Image > "$B/strings-a104.txt" || { echo STRINGS_A104_FAIL; exit 1; }
comm -23 "$B/strings-a102.txt" "$B/strings-a104.txt" > /tmp/y700/kbuild/a104-strings-lost.txt
if [ -s /tmp/y700/kbuild/a104-strings-lost.txt ]; then
	echo A104_STRING_LOSS
	head -40 /tmp/y700/kbuild/a104-strings-lost.txt
	exit 1
fi
echo "no string regressions: a102=$(wc -l < $B/strings-a102.txt) a104=$(wc -l < $B/strings-a104.txt)"
strings arch/arm64/boot/Image | grep -q 'finger input ready' || { echo TOUCH_DRIVER_LOST; exit 1; }
strings arch/arm64/boot/Image | grep -q 'global state already finalized' || { echo A96_KERNEL_FIX_LOST; exit 1; }
strings arch/arm64/boot/Image | grep -q 'Zap shader not enabled' || { echo ZAP_STR_LOST; exit 1; }
strings arch/arm64/boot/Image | grep -c 'novatek,nt36523n-spi'
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
ls -l arch/arm64/boot/Image "$B/armada-boot/vmlinuz" "$B/a104-kernel.img"
sha256sum arch/arm64/boot/Image

# ---- DTB: same generator twice, first without Y700_GPU so the A104 delta has
# a reference built by this very script.  a1.dtb is rewritten by every
# mk_a1_dtb.py run, and a run that dies after writing it leaves the round
# comparing a DTB against itself. ----
export Y700_EXTRA_DISABLE='displayport-controller@ae90000'
export Y700_APPS_SMMU=1
unset Y700_A65_BL_OFF
export Y700_A70=1
export Y700_A102=1
unset Y700_GPU
refout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_A102_REF_FAIL; printf '%s\n' "$refout"; exit 1; }
printf '%s\n' "$refout" | grep -q 'A102: touchscreen@0 panel -> ' || { echo A102_REF_STEP_MISSING; printf '%s\n' "$refout"; exit 1; }
if printf '%s\n' "$refout" | grep -q 'A104: gpu stack on'; then
	echo A104_LEAKED_INTO_THE_A102_REFERENCE
	exit 1
fi
cp -f "$B/a1.dtb" "$B/a1.dtb.a102" || exit 1
cp -f "$B/a1.dts" "$B/a1.dts.a102" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb.a102" > "$B/chk_a102.dts" || { echo DTC_A102_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a102.dts" > /tmp/y700/kbuild/a104-chk-a102.log || { echo CHK_A102_REF_FAIL; tail -25 /tmp/y700/kbuild/a104-chk-a102.log; exit 1; }
grep -E '^(OK|BAD) +(gpu@3d00000|gmu@3d6a000|clock-controller@3d90000)' /tmp/y700/kbuild/a104-chk-a102.log
grep -q '^BAD' /tmp/y700/kbuild/a104-chk-a102.log && { echo A102_REFERENCE_BROKEN; exit 1; }

export Y700_GPU=1
dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; printf '%s\n' "$dtbout"; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A70: y700-stub-panel added' || { echo A70_STEP_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A102: touchscreen@0 panel -> ' || { echo A102_STEP_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A104: gpu stack on - gpu@3d00000' || { echo A104_STEP_MISSING; exit 1; }

"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a104.dts" || { echo DTC_FAIL; exit 1; }
Y700_GPU=1 python3 "$B/chk_minimal.py" "$B/chk_a104.dts" || { echo CHK_FAIL; exit 1; }

echo "=== A104 dtb delta vs A102 ==="
diff "$B/chk_a102.dts" "$B/chk_a104.dts" || true

python3 - "$B/chk_a102.dts" "$B/chk_a104.dts" <<'PYGATE' || { echo A104_DTB_GATE_FAIL; exit 1; }
import sys

# gpucc was promoted by the A48 sweep long ago, so it is already on in A102 and
# only three nodes actually move here.
GPU = {'gpu@3d00000', 'gmu@3d6a000', 'iommu@3da0000'}


def parse(text):
    nodes, stack = {}, []
    for ln in text.split('\n'):
        s = ln.strip()
        if not s:
            continue
        if s.endswith('{'):
            name = s[:-1].strip()
            nodes['/'.join(stack + [name])] = []
            stack.append(name)
        elif s.startswith('}'):
            stack.pop()
        elif stack:
            nodes['/'.join(stack)].append(s)
    return {k: sorted(v) for k, v in nodes.items()}


def one(nodes, leaf):
    hits = [k for k in nodes if k.split('/')[-1] == leaf]
    assert len(hits) == 1, 'node %s found %d times' % (leaf, len(hits))
    return hits[0]


a = parse(open(sys.argv[1], encoding='utf-8').read())
b = parse(open(sys.argv[2], encoding='utf-8').read())
assert set(a) == set(b), 'node set changed: %s' % (set(a) ^ set(b))
off_a = {k.split('/')[-1] for k, v in a.items() if 'status = "disabled";' in v}
off_b = {k.split('/')[-1] for k, v in b.items() if 'status = "disabled";' in v}
print('disabled a102=%d a104=%d unpinned=%s newly_off=%s'
      % (len(off_a), len(off_b), sorted(off_a - off_b), sorted(off_b - off_a)))
assert off_a - off_b == GPU, 'A104 unpinned %s' % sorted(off_a - off_b)
assert not (off_b - off_a), 'A104 pinned something new off: %s' % sorted(off_b - off_a)
smmu = [q for q in b[one(b, 'iommu@3da0000')] if q.startswith('phandle = ')][0].split('<')[1].split('>')[0]
print('adreno smmu phandle %s' % smmu)
allowed_off = {'status = "disabled";'}
allowed_on = {'status = "okay";', 'iommus = <%s 0x00 0x400 0xb0 0x01 0x400>;' % smmu,
              'iommus = <%s 0x05 0x400>;' % smmu}
changed = []
for k in a:
    gone, came = set(a[k]) - set(b[k]), set(b[k]) - set(a[k])
    if gone or came:
        changed.append((k.split('/')[-1], gone, came))
        assert gone <= allowed_off and came <= allowed_on, 'unexpected edit in %s: -%s +%s' % (k, gone, came)
print('edited nodes: %d' % len(changed))
for k, gone, came in changed:
    print('  %s -%s +%s' % (k, sorted(gone), sorted(came)))
assert {k for k, _, _ in changed} == GPU, 'A104 touched more than the gpu stack'
for node in ('gpu@3d00000', 'gmu@3d6a000'):
    assert any(q.startswith('iommus = <%s ' % smmu) for q in b[one(b, node)]), '%s lost its adreno smmu binding' % node
zap = one(b, 'zap-shader') if 'zap-shader' in [k.split('/')[-1] for k in b] else None
assert zap, 'zap-shader node missing'
assert any(q.startswith('memory-region = ') for q in b[zap]), 'zap-shader lost its memory-region'
assert any(q.startswith('firmware-name = ') for q in b[zap]), 'zap-shader lost firmware-name'
print('A104 dtb gate ok')
PYGATE

cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a104.img" || { echo PACK_FAIL; exit 1; }

python3 - "$B/out/boot-b-a104.img" "$B/a1.dtb" <<'PYIMG' || { echo A104_DTB_NOT_IN_IMAGE; exit 1; }
import sys
img = open(sys.argv[1], 'rb').read()
dtb = open(sys.argv[2], 'rb').read()
off = img.find(dtb)
print('boot image %d bytes, a1.dtb %d bytes, found at %s' % (len(img), len(dtb), hex(off) if off >= 0 else 'NOT_FOUND'))
sys.exit(0 if off >= 0 else 1)
PYIMG
for s in 'finger input ready' 'lenovo,y700-nt36523n' 'global state already finalized' 'a730_sqe.fw' 'gmu_gen70000.bin' 'a730_zap.mdt'; do
	strings "$B/out/boot-b-a104.img" | grep -q "$s" || { echo "A104_IMAGE_LOST $s"; exit 1; }
	echo "image contains $s"
done
strings "$B/out/boot-b-a104.img" | grep -q 'qcom,adreno-730' || { echo A104_GPU_NODE_LOST; exit 1; }

cp -f "$B/out/boot-b-a104.img" /tmp/y700/e15/ || exit 1
cp -f /tmp/y700/e15/boot-b-a104.img /root/y700-artifacts/ || exit 1
ls -l /tmp/y700/e15/boot-b-a104.img /root/y700-artifacts/boot-b-a104.img
sha256sum /tmp/y700/e15/boot-b-a104.img
echo "=== a104 end $(date -u) ==="
echo A104_ALL_OK