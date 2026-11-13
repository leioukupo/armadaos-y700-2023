#!/bin/bash
# Adreno GPU firmware has to be inside the initramfs.
#
# DRM_MSM is built-in (packages/kernel/config/armada-kernel.config.overrides), so
# the GMU/sqe/zap requests happen during initcalls, before switch_root mounts the
# real root. dracut only collects MODULE_FIRMWARE from modules, so the built-in
# case has to be carried here; without it the GPU comes up with no GMU and Mesa
# has no render node.

check() {
    # 255 = explicit --add only, see build_files/55-generate-initramfs.sh.
    local n
    n=$(find "${dracutsysrootdir:-}/usr/lib/firmware/qcom" -maxdepth 4 -type f \
            \( -name 'gmu_*.bin' -o -name '*_sqe.fw' -o -name '*_aqe.fw' \
               -o -name '*_zap.mdt' \) 2>/dev/null | wc -l)
    [ "${n}" -gt 0 ] || return 1
    return 255
}

depends() {
    return 0
}

install() {
    local f count=0
    while IFS= read -r f; do
        inst_simple "${f#"${dracutsysrootdir:-}"}"
        count=$((count + 1))
    done < <(find "${dracutsysrootdir:-}/usr/lib/firmware/qcom" -maxdepth 4 -type f \
                 \( -name 'gmu_*.bin' -o -name '*_sqe.fw' -o -name '*_aqe.fw' \
                    -o -name '*_zap.mdt' -o -name '*_zap.b[0-9][0-9]' \) \
                 2>/dev/null | LC_ALL=C sort)
    echo "armada-gpu-firmware: ${count} GPU firmware files in the initramfs" >&2
}