#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Put an ArmadaOS root image and its boot payload onto the TB320FC over firehose, then
# pin the boot slots - the reinstall half of the install flow.
#
#   ROOT_IMG=… BOOT_IMG=… install/ufs-install.sh            (firehose, board in 9008)
#
# Writes are checked by reading them back, because this board gives no other feedback: there
# is no ABL log channel and no fastboot fetch (PROGRESS A203/A204). boot is verified in full;
# the root is verified at both ends of the written range, since reading 30+ GiB back over
# firehose costs as much as writing it, and a truncated stream is the failure this catches.
#
# Inputs that come from THIS device, not from the repo - see README.md:
#   EDL_ROM / LOADER        the EDL package and its xbl_s_devprg_ns.melf
#   LR_LBA                  linuxroot's first sector on LUN0 (printgpt offset / 4096)
#   BOOT_LBA                the boot_* partition you are writing, on LUN4
#   --lr-sectors            how much of the root to write (the used part, not 345 GB)
# The GPT edits are rebuilt from live dumps; never write the rom's GPT tables here.
set -uo pipefail

EDL_ROM=${EDL_ROM:?EDL_ROM=<unpacked edl package>}
LOADER=${LOADER:?LOADER=<xbl_s_devprg_ns.melf>}
EDL=${EDL:-/srv/y700/edlvenv/bin/python /srv/y700/edltool/edl.py --loader=$LOADER --memory=ufshcd}
WORK=${WORK:-$EDL_ROM/../ufs-install}
SERIAL=${SERIAL:-HA1WZJJ5}
HERE=$(cd "$(dirname "$0")" && pwd)

ROOT_IMG=${ROOT_IMG:-}
BOOT_IMG=${BOOT_IMG:-}
LR_LBA=${LR_LBA:-36827048}
LR_SECTORS=${LR_SECTORS:-}          # empty = derive from the e2image dump size
BOOT_LBA=${BOOT_LBA:-108422}        # boot_a on LUN4; boot_b is 374511
BOOT_SECTORS=${BOOT_SECTORS:-24576} # 96 MiB boot partition in 4 KiB LBAs
PIN=${PIN:-}                        # a|b, empty = do not touch LUN4 flags
UD_END=${UD_END:-36827047}
LR_END=${LR_END:-121268218}

# End offset (bytes) of the last non-hole region of a sparse file.
last_data_extent() { # last_data_extent <file>
    python3 - "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
end = off = 0
while True:
    try:
        off = os.lseek(fd, off, os.SEEK_DATA)
    except OSError:
        break
    nxt = os.lseek(fd, off, os.SEEK_HOLE)
    end = max(end, nxt)
    off = nxt
print(end)
PY
}

log() { echo "[ufs-install $(date +%H:%M:%S)] $*"; }
E() { timeout 3000 $EDL "$@"; }
# Read a window back off the device and compare it with the same window of the source file.
# <base_lba> is where the file begins on the device, so the dd skip stays file-relative.
verify_window() { # verify_window <device_lba> <sectors> <lun> <file> <base_lba>
    local lba=$1 sect=$2 lun=$3 file=$4 base=$5 a b avail
    avail=$(( ($(stat -c %s "$file") / 4096) - (lba - base) ))
    [ "$sect" -gt "$avail" ] && sect=$avail
    E rs "$lba" "$sect" "$WORK/readback.bin" --lun="$lun" > /dev/null 2>&1
    a=$(sha256sum "$WORK/readback.bin" | cut -c1-64)
    b=$(dd if="$file" bs=4096 skip=$((lba - base)) count="$sect" status=none | sha256sum | cut -c1-64)
    rm -f "$WORK/readback.bin"
    if [ "$a" = "$b" ]; then log "  read-back ok: lba $lba, $sect sectors ($a)"
    else log "  READ-BACK MISMATCH at lba $lba got=$a want=$b"; return 1; fi
}
# The head window covers the superblock, group 0 and the root inode; the tail window is what
# a truncated stream would miss. Reading the whole root back costs as much as writing it.
verify_sample() { # verify_sample <lba> <sectors> <lun> <file>
    local lba=$1 sect=$2 lun=$3 file=$4 win=16384
    [ "$sect" -lt "$win" ] && win=$sect
    verify_window "$lba" "$win" "$lun" "$file" "$lba" || return 1
    if [ "$sect" -gt "$win" ]; then
        verify_window $((lba + sect - win)) "$win" "$lun" "$file" "$lba" || return 1
    fi
}

mkdir -p "$WORK/gptbak"
lsusb | grep -q '05c6:9008' || {
    log "not in EDL, asking fastboot"
    timeout 30 fastboot -s "$SERIAL" oem reboot-edl > /dev/null 2>&1
    sleep 8
}
lsusb | grep -q '05c6:9008' || { echo "FATAL: no 05c6:9008"; exit 1; }

log 'step 1: dump the live GPTs (primary + backup) for LUN0 and LUN4'
for lun in 0 4; do
    E rs 0 6 "$WORK/gptbak/prim$lun.bin" --lun=$lun > /dev/null 2>&1
    alt=$(python3 -c "import struct;d=open('$WORK/gptbak/prim$lun.bin','rb').read();o=d.find(b'EFI PART');print(struct.unpack_from('<Q',d,o+32)[0])")
    echo "$alt" > "$WORK/alt$lun"
    E rs $((alt - 4)) 5 "$WORK/gptbak/back$lun.bin" --lun=$lun > /dev/null 2>&1
    log "  lun$lun backup_lba=$alt"
done

if [ -n "$PIN" ] || [ -n "$ROOT_IMG" ]; then
    log 'step 2: re-slice LUN0 (userdata + linuxroot) and pin LUN4 to slot '"${PIN:-keep}"
    python3 "$HERE/gpt-slice-pin.py" --dir "$WORK" --userdata-end "$UD_END" \
        --lr-start "$LR_LBA" --lr-end "$LR_END" ${PIN:+--pin $PIN}
    for pair in "0 new_prim0" "0 new_back0"; do set -- $pair
        E ws $([ "$2" = new_prim0 ] && echo 0 || echo $(($(cat "$WORK/alt0") - 4))) \
            "$WORK/$2.bin" --lun=$1 2>&1 | tail -1 | sed "s/^/  /"
    done
    if [ -n "$PIN" ]; then
        E ws 1 "$WORK/new_prim4.bin" --lun=4 2>&1 | tail -1 | sed 's/^/  /'
        E ws $(($(cat "$WORK/alt4") - 4)) "$WORK/new_back4.bin" --lun=4 2>&1 | tail -1 | sed 's/^/  /'
    fi
    log '  tables now:'
    E printgpt --lun=0 2>&1 | grep -E '^\s+(userdata|linuxroot|misc|metadata):' | sed 's/, UUID.*//' | sed 's/^/    /'
    E printgpt --lun=4 2>&1 | grep -E '^\s*(boot_a|boot_b):' | sed 's/, UUID.*//' | sed 's/^/    /'
fi

if [ -n "$ROOT_IMG" ]; then
    [ -f "$ROOT_IMG" ] || { echo "no root image: $ROOT_IMG"; exit 1; }
    src="$ROOT_IMG"
    if [ -z "$LR_SECTORS" ]; then
        # How much of the image actually holds bytes: the image is a 345 GB sparse file, so
        # its size is meaningless, and writing all of it over firehose is hours of zeros. Walk
        # the data extents and stop after the last one; past that everything reads as zero and
        # no bitmap that got written points further out.
        used_bytes=$(last_data_extent "$ROOT_IMG")
        [ "${used_bytes:-0}" -gt 0 ] || { echo "cannot find any data in $ROOT_IMG"; exit 1; }
        LR_SECTORS=$(( (used_bytes + 4095) / 4096 ))
        log "step 3: $(du -h "$ROOT_IMG" | cut -f1) allocated, last byte at $((used_bytes / 2**30)) GiB -> writing $LR_SECTORS LBAs to linuxroot lba $LR_LBA"
    else
        log "step 3: writing $(basename "$src") to linuxroot lba $LR_LBA (LR_SECTORS=$LR_SECTORS)"
    fi
    # An e2image dump is sparse over the whole filesystem, so its apparent size proves
    # nothing: e2image -r leaves the data blocks as holes, and a board flashed from it boots
    # into a root whose every file reads back as zeros. Compare what is allocated instead.
    if [ -f "$ROOT_IMG.e2" ]; then
        img_alloc=$(du -b "$ROOT_IMG" | cut -f1)
        e2_alloc=$(du -b "$ROOT_IMG.e2" | cut -f1)
        if [ "$e2_alloc" -ge "$img_alloc" ]; then
            src="$ROOT_IMG.e2"
            log "  using $(basename "$ROOT_IMG.e2"): it holds as much data as the image"
        else
            log "  ignoring $(basename "$ROOT_IMG.e2") ($((e2_alloc / 2**20)) MiB allocated): metadata only, the image holds $((img_alloc / 2**20)) MiB"
        fi
    fi
    E ws "$LR_LBA" "$src" --lun=0 2>&1 | tail -1 | sed 's/^/  /'
    verify_sample "$LR_LBA" "$LR_SECTORS" 0 "$src" || exit 1
    # The boot payload addresses this filesystem by UUID or PARTLABEL: print both so the
    # payload blob can be checked against them (a mismatch shows up as "boot straight back
    # to fastboot", PROGRESS A162).
    log "  root fs: $(blkid -o value -s LABEL "$src" 2>/dev/null) / $(blkid -o value -s UUID "$src" 2>/dev/null) (from the image file)"
fi

if [ -n "$BOOT_IMG" ]; then
    [ -f "$BOOT_IMG" ] || { echo "no boot image: $BOOT_IMG"; exit 1; }
    log "step 4: writing $(basename "$BOOT_IMG") to LUN4 lba $BOOT_LBA"
    E ws "$BOOT_LBA" "$BOOT_IMG" --lun=4 2>&1 | tail -1 | sed 's/^/  /'
    verify_window "$BOOT_LBA" "$BOOT_SECTORS" 4 "$BOOT_IMG" "$BOOT_LBA" || exit 1
fi

log 'step 5: reset'
timeout 90 ${EDL% --memory=*} reset 2>&1 | tail -1
log 'UFS_INSTALL_DONE'