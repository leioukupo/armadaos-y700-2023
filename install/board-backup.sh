#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Back up the boot/vbmeta chain of the TB320FC from a RUNNING system.
#
# Why this exists: kShimC packing needs a pristine --stock-boot for the exact slot, and
# every write to boot_* or vbmeta_* is irreversible from fastboot on this ABL - it does
# not implement fetch, so there is no "read it back out and keep it" path once the board
# is in fastboot. On 2026-11-26 a vbmeta_b was overwritten from the EDL package without a
# backup, and the EDL package's vbmeta/dtbo/vendor_boot are NOT the device's versions
# (PROGRESS A203/A204), so there was nothing to restore. This script is the one-shot
# answer: run it before any boot_* / vbmeta_* write.
#
# Run as root on either system:
#   Android  : adb root / su, then sh board-backup.sh
#   ArmadaOS : sudo sh board-backup.sh
#
# Usage: board-backup.sh [OUTDIR]        (default ./tb320fc-backup-<date>)
set -u
OUT="${1:-./tb320fc-backup-$(date +%Y%m%d-%H%M)}"
mkdir -p "$OUT" || exit 1

# Both systems carry partlabels, under different names.
BYNAME=""
for d in /dev/disk/by-partlabel /dev/block/by-name; do
    [ -d "$d" ] && BYNAME="$d" && break
done
[ -n "$BYNAME" ] || { echo "no /dev/disk/by-partlabel or /dev/block/by-name"; exit 1; }
echo "partlabels: $BYNAME"

PARTS="boot_a boot_b vendor_boot_a vendor_boot_b init_boot_a init_boot_b dtbo dtbo_a dtbo_b
       vbmeta vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b vbmeta_vendor_a vbmeta_vendor_b
       abl_a abl_b xbl_a xbl_b xbl_config_a xbl_config_b misc metadata super"
# super is 2-8 GB; only its first sectors are interesting (the VAB metadata), so it is
# handled separately at the end.
saved=0
for p in $PARTS; do
    src="$BYNAME/$p"
    [ -b "$src" ] || { echo "  skip $p (no such partition here)"; continue; }
    src=$(readlink -f "$src")
    size=$(blockdev --getsize64 "$src" 2>/dev/null || echo 0)
    printf '  %-18s %12s B  ' "$p" "$size"
    if dd if="$src" of="$OUT/$p.img" bs=1M status=none; then
        echo "ok"
        saved=$((saved + 1))
    else
        echo "FAILED"
        rm -f "$OUT/$p.img"
    fi
done

for p in super; do
    src="$BYNAME/$p"; [ -b "$src" ] || continue
    dd if="$(readlink -f "$src")" of="$OUT/super-head-64MiB.img" bs=1M count=64 status=none &&
        echo "  super head 64 MiB saved (VAB metadata lives in it)"
done

# The GPTs of the two LUNs that matter, as visible from Linux, plus the geometry the
# board reports. gpt-slice-pin.py needs a live table, not the rom's.
for disk in /dev/sd? /dev/sda; do
    [ -b "$disk" ] || continue
    name=$(basename "$disk")
    sgdisk -i "$disk" > "$OUT/gpt-$name.txt" 2>/dev/null || fdisk -l "$disk" > "$OUT/gpt-$name.txt" 2>/dev/null
done
for part in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -b "/dev/sda$part" ] || continue
    pt=$(cat "/sys/class/block/sda$part/partition" 2>/dev/null)
    echo "  sda$part -> partition $pt" >> "$OUT/partition-map.txt"
done

cat > "$OUT/what.txt" <<HERE
board=TB320FC(Y700 Gen 2) serial=$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null || getprop ro.serialno 2>/dev/null || echo unknown)
taken=$(date -u +%Y-%m-%dT%H:%M:%SZ)
system=$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null || getprop ro.build.display.id 2>/dev/null)
slot=$(cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep '^androidboot.slot_suffix=' || getprop ro.boot.slot_suffix 2>/dev/null)
note=kShimC --stock-boot base AND the only rollback point for boot_*/vbmeta_*. The EDL
note=package's files with the same names are a different (older) build: never substitute.
HERE
( cd "$OUT" && sha256sum *.img *.txt > SHA256SUMS 2>/dev/null )
echo "saved=$saved out=$OUT"
[ "$saved" -gt 0 ] && echo "BOARD_BACKUP_OK $OUT" || { echo "nothing saved - wrong system or missing permissions"; exit 1; }
