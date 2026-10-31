#!/bin/sh
# TB320FC / SM8475 (Y700 Gen2) end-to-end boot build.
#
# Runs inside the builder container at /work. Inputs:
#   source.tar                     kShimC source tree (extracted to source/)
#   inputs/boot-stock.img          stock boot_a.img (96 MiB, from the device)
#   inputs/avbtool.py              avbtool from packages/kshim-tools/vendor
#   build_android_boot.py          packer from this directory
#   kshim-gen2-entry-protocol.patch  kShimC Gen2 entry protocol patch
# Outputs:
#   boot-candidate/boot-packed.img  packed 96 MiB boot image
#   evidence/                       per-step logs, validation reports
set -eu
cd /work
mkdir -p evidence
step() {
    label=$1
    shift
    printf '%s\n' "$label"
    set +e
    "$@" > "evidence/$label.log" 2>&1
    status=$?
    set -e
    printf '%s\n' "$status" > "evidence/$label.exit"
    if [ "$status" != 0 ]; then tail -n 60 "evidence/$label.log"; exit "$status"; fi
}
if [ "${RESUME_AT:-}" != kshim ]; then
    tar -xf source.tar -C source
fi
sed -i 's/\r$//' source/ports/crdk/patches/*.patch 2>/dev/null || true
mkdir -p boot-candidate
step kshim-patch sh -c 'cd source && (git apply -p1 ../kshim-gen2-entry-protocol.patch || patch -p1 < ../kshim-gen2-entry-protocol.patch)'
step stock-roundtrip python3 -B build_android_boot.py \
    --stock-boot inputs/boot-stock.img \
    --round-trip-only \
    --report evidence/stock-roundtrip.report.json
step runtime python3 source/tools/build_runtime.py \
    --config source/configs/tb320fc_android_defconfig \
    --out out/runtime --jobs 6
step pack python3 -B build_android_boot.py \
    --stock-boot inputs/boot-stock.img \
    --runtime out/runtime/kShimC.bin \
    --avbtool inputs/avbtool.py \
    --out boot-candidate/boot-packed.img \
    --report evidence/pack.report.json
cp out/runtime/validation.json evidence/runtime-validation.json
cp out/runtime/.config evidence/runtime.config
aarch64-linux-gnu-size out/runtime/kShimC.elf > evidence/runtime-size.txt
printf '0\n' > build.exit
