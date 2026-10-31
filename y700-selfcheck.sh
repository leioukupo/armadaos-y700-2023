#!/usr/bin/env bash
# =====================================================================
# Y700 二代 (TB320FC / SM8475 / QCA6490) 自查采集脚本
# 只读：不修改、不刷写任何分区。输出一份报告文本，交给 AI 分析。
#
# 用法：
#   chmod +x y700-selfcheck.sh
#   ./y700-selfcheck.sh              # 默认生成 y700-report-<时间>.txt
#   ./y700-selfcheck.sh my.txt       # 指定输出文件名
#
# 环境：
#   - PC + adb（推荐，需开启 USB 调试并授权）
#   - 或在平板的 Termux 里直接跑（脚本会自动改用本机命令）
# =====================================================================
set -u
ADB="${ADB:-adb}"
OUT="${1:-y700-report-$(date +%Y%m%d-%H%M%S).txt}"
HAVE_ADB=0
if command -v "$ADB" >/dev/null 2>&1 && "$ADB" get-state >/dev/null 2>&1; then
    HAVE_ADB=1
fi
if [ "$HAVE_ADB" = 1 ]; then
    SH()  { "$ADB" shell "$@" 2>/dev/null; }
    RSH() { "$ADB" shell "su -c '$*'" 2>/dev/null; }
    XOUT() { "$ADB" exec-out "$@" 2>/dev/null; }
else
    SH()  { sh -c "$*" 2>/dev/null; }
    RSH() { su -c "$*" 2>/dev/null; }
    XOUT() { sh -c "$*" 2>/dev/null; }
fi
# 统一输出到屏幕 + 文件
exec > >(tee "$OUT") 2>&1
section() { echo; echo "==================== $* ===================="; }
cmd()     { echo "---- \$ $*"; "$@" 2>&1 | head -"${MAXLINES:-120}"; echo; }
note()    { echo "# $*"; }
echo "Y700 QCA6490 自查报告"
echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "采集方式: $([ "$HAVE_ADB" = 1 ] && echo 'PC + adb' || echo '本机 shell/Termux')"
# ---------------------------------------------------------------------
section "1. 设备基本信息"
SH 'getprop | head -60'
if [ "$HAVE_ADB" = 1 ]; then
    echo "---- 关键属性"
    "$ADB" shell "getprop | grep -Ei 'ro.product|ro.board|ro.boot|ro.soc|ro.build.version|ro.hardware'" 2>/dev/null
else
    for k in ro.product.device ro.product.model ro.board.platform ro.boot.hardware ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.slot_suffix; do
        printf '%s = %s\n' "$k" "$(getprop "$k" 2>/dev/null)"
    done
fi
echo
echo "---- 内核版本"
SH 'uname -a; cat /proc/version'
echo
echo "---- cmdline"
SH 'cat /proc/cmdline'
echo
echo "---- bootconfig (如有)"
SH 'cat /proc/bootconfig 2>/dev/null | head -40'
# ---------------------------------------------------------------------
section "2. 分区表（需 root，仅列出）"
RSH 'ls -l /dev/block/by-name' || note "root 不可用，跳过（可选）"
# ---------------------------------------------------------------------
section "3. PCI 设备枚举（重点：找 17cb:1103）"
SH 'for d in /sys/bus/pci/devices/*; do echo "### $d"; cat "$d/uevent" 2>/dev/null; done'
echo
echo "---- vendor/device/subsystem 汇总"
SH 'for d in /sys/bus/pci/devices/*; do \
      printf "%s vendor=%s device=%s subsys=%s:%s class=%s driver=%s\n" \
        "$d" "$(cat $d/vendor 2>/dev/null)" "$(cat $d/device 2>/dev/null)" \
        "$(cat $d/subsystem_vendor 2>/dev/null)" "$(cat $d/subsystem_device 2>/dev/null)" \
        "$(cat $d/class 2>/dev/null)" "$(basename $(readlink -f $d/driver 2>/dev/null) 2>/dev/null)"; \
    done'
echo
echo "---- 只列出高通无线设备 (17cb)"
SH 'for d in /sys/bus/pci/devices/*; do \
      if [ "$(cat $d/vendor 2>/dev/null)" = "0x17cb" ]; then \
        echo "MATCH: $d  device=$(cat $d/device) subsys=$(cat $d/subsystem_vendor):$(cat $d/subsystem_device)"; \
      fi; \
    done'
# ---------------------------------------------------------------------
section "4. 网络接口（wlan0 的 PCI 身份）"
SH 'ls /sys/class/net'
echo
SH 'for n in /sys/class/net/*; do echo "$n: $(cat $n/address 2>/dev/null)"; done'
echo
echo "---- wlan* 关联的 PCI 设备"
SH 'for n in /sys/class/net/wlan*; do [ -e "$n" ] || continue; \
      echo "### $n"; readlink -f "$n/device"; \
      cat "$n/device/vendor" "$n/device/device" "$n/device/subsystem_vendor" "$n/device/subsystem_device" 2>/dev/null; done'
# ---------------------------------------------------------------------
section "5. cnss / 平台设备"
SH 'ls /sys/bus/platform/drivers/ | grep -iE "cnss|wlan|wcn"'
echo
SH 'ls /sys/bus/platform/devices/ | grep -iE "cnss|wlan|wcn"'
echo
SH 'for d in /sys/bus/platform/devices/*cnss* /sys/bus/platform/devices/*wlan* /sys/bus/platform/devices/*wcn*; do \
      [ -e "$d" ] || continue; echo "### $d"; cat "$d/uevent" 2>/dev/null; done'
# ---------------------------------------------------------------------
section "6. 内核模块 / 驱动"
SH 'lsmod | grep -iE "qca|cld|cnss|wlan|ath"'
echo
SH 'ls /sys/module | grep -iE "qca|cld|cnss|wlan|ath"'
echo
SH 'ls -l /vendor/lib/modules 2>/dev/null | grep -iE "qca|cld|cnss|wlan"'
# ---------------------------------------------------------------------
section "7. 固件目录（找 bd_*.elf / amss / m3 / bdwlan）"
SH 'ls /vendor/firmware 2>/dev/null | grep -iE "bd_|bdwlan|amss|m3|qca|wlan|6490"'
echo
echo "---- firmware 一级目录"
SH 'ls /vendor/firmware 2>/dev/null | head -60'
echo
echo "---- firmware_mnt"
SH 'ls /vendor/firmware_mnt 2>/dev/null | head -20; ls /vendor/firmware_mnt/image 2>/dev/null | grep -iE "wlan|qca" | head'
# ---------------------------------------------------------------------
section "8. vendor Wi-Fi 配置"
SH 'ls -R /vendor/etc/wifi 2>/dev/null | head -60'
echo
echo "---- WCNSS / qca 配置文件头"
SH 'for f in /vendor/etc/wifi/WCNSS_qcom_cfg.ini /vendor/etc/wifi/qca6490/*; do \
      [ -f "$f" ] && { echo "### $f"; head -40 "$f"; }; done'
# ---------------------------------------------------------------------
section "9. persist 分区里的 WLAN 数据（需 root，只读）"
RSH 'ls -l /mnt/vendor/persist/wlan' || note "无 root 或路径不存在，跳过"
RSH 'head -40 /mnt/vendor/persist/wlan/WCNSS_qcom_cfg.ini' || true
# ---------------------------------------------------------------------
section "10. dmesg 关键日志（cnss/qca/wlan/pcie/board id）"
RSH 'dmesg' | grep -iE 'cnss|qca|wlan|wcn|pcie|board.?id|chip.?id|subsys' | tail -200
# ---------------------------------------------------------------------
section "11. 设备树（FDT）"
SH 'ls -l /sys/firmware/fdt 2>/dev/null; ls /proc/device-tree 2>/dev/null | head'
if [ "$HAVE_ADB" = 1 ]; then
    if XOUT su -c 'cat /sys/firmware/fdt' > fdt-y700.dtb 2>/dev/null && [ -s fdt-y700.dtb ]; then
        echo "已导出 fdt-y700.dtb ($(wc -c < fdt-y700.dtb) 字节)"
        if command -v dtc >/dev/null 2>&1; then
            dtc -I dtb -O dts -o fdt-y700.dts fdt-y700.dtb 2>/dev/null && \
                echo "已反编译 fdt-y700.dts（可搜 cnss/wifi/pcie/wcn）"
        else
            note "本机没有 dtc，可安装 device-tree-compiler 后手动反编译"
        fi
    else
        note "无法读取 /sys/firmware/fdt（缺 root 或内核未导出）"
    fi
fi
echo
echo "---- 设备树里与无线相关的节点（若 fdt-y700.dts 存在）"
if [ -f fdt-y700.dts ]; then
    grep -n -iE 'cnss|wifi|wlan|wcn|pcie' fdt-y700.dts | head -60
fi
# ---------------------------------------------------------------------
section "12. 完成"
echo "报告已写入: $OUT"
echo "把这行报告 + y700-gen2-qca6490-selfcheck.md 一起交给 AI。"