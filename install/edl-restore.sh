#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full stock-Android restore of a TB320FC (Y700 Gen 2) from an unpacked EDL package.
#
#   EDL_ROM=/path/to/unpacked_rom install/edl-restore.sh
#
# The board has to be in EDL (05c6:9008). From fastboot that is
#   fastboot -s <serial> oem reboot-edl
# (plain "reboot edl" / "oem edl" are unknown to this ABL).
#
# Order matters, and every step here is a scar:
#   1 dump the live GPTs of all six LUNs first - the geometry of this UFS chip is the only
#     correct basis for the tables we write back, and there is no undo for a bad table;
#   2 write the rom's images;
#   3 clear the DDR training cache the way the rom intends (LUN3 lba 64);
#   4 rebuild LUN0 from the live dump into the stock shape (no linuxroot, userdata to the
#     last usable LBA) instead of trusting the rom's GPT/patch xml;
#   5 erase userdata + metadata + misc. This is the step that decides whether the board
#     boots at all: the rom's own userdata_*.img/metadata.img carry an older geometry and
#     an old FBE keyblob, and writing them onto this device leaves it in a state where
#     every slot falls back to fastboot (PROGRESS A204 - Lenovo's "恢复出厂设置才能开机"
#     literally means this erase);
#   6 reset out of firehose.
set -uo pipefail

EDL_ROM=${EDL_ROM:?EDL_ROM=<unpacked edl package>}
LOADER=${LOADER:?LOADER=<the xbl_s_devprg_ns.melf that contents.xml names as device_programmer>}
EDL=${EDL:-/srv/y700/edlvenv/bin/python /srv/y700/edltool/edl.py --loader=$LOADER --memory=ufshcd}
WORK=${WORK:-$EDL_ROM}
SERIAL=${SERIAL:-HA1WZJJ5}
HERE=$(cd "$(dirname "$0")" && pwd)
log() { echo "[edl-restore $(date +%H:%M:%S)] $*"; }
E() { timeout 3000 $EDL "$@"; }

mkdir -p "$WORK/gptbak"
if ! lsusb | grep -q '05c6:9008'; then
    log "not in EDL, asking fastboot for it"
    timeout 30 fastboot -s "$SERIAL" oem reboot-edl > /dev/null 2>&1
    sleep 8
fi
lsusb | grep -q '05c6:9008' || { echo "FATAL: no 05c6:9008 on this host"; exit 1; }

log 'step 1: dump live GPTs (primary + backup) for every LUN'
for lun in 0 1 2 3 4 5; do
    E rs 0 6 "$WORK/gptbak/prim$lun.bin" --lun="$lun" > /dev/null 2>&1
    alt=$(python3 -c "import struct;d=open('$WORK/gptbak/prim$lun.bin','rb').read();o=d.find(b'EFI PART');print(struct.unpack_from('<Q',d,o+32)[0])")
    E rs $((alt - 4)) 5 "$WORK/gptbak/back$lun.bin" --lun="$lun" > /dev/null 2>&1
    echo "$alt" > "$WORK/alt$lun"
    log "  lun$lun backup_lba=$alt"
done

log 'step 2: write the rom images (resumable)'
EDL_ROM=$EDL_ROM EDL="$EDL" WORK=$WORK bash "$HERE/rom-flash.sh" 2>&1 | tee "$WORK/flash.log" | grep -E 'FAIL|ALL_WRITES_DONE' | tail -6
grep -q ALL_WRITES_DONE "$WORK/flash.log" || { log 'FLASH_INCOMPLETE'; exit 2; }

log 'step 3: clear the DDR training cache (LUN3 lba 64, 256 LBAs)'
dd if=/dev/zero of="$WORK/zeros_1m.bin" bs=4096 count=256 status=none
E ws 64 "$WORK/zeros_1m.bin" --lun=3 2>&1 | tail -1

log 'step 4: rebuild LUN0 into the stock shape from the live dumps'
python3 "$HERE/gpt-stock.py" --prim0 "$WORK/gptbak/prim0.bin" --back0 "$WORK/gptbak/back0.bin" \
    --backup-lba "$(cat "$WORK/alt0")" --out-prim "$WORK/new_prim0.bin" --out-back "$WORK/new_back0.bin"
E ws 0 "$WORK/new_prim0.bin" --lun=0 2>&1 | tail -1
E ws $(($(cat "$WORK/alt0") - 4)) "$WORK/new_back0.bin" --lun=0 2>&1 | tail -1

log 'step 5: verify the tables'
E printgpt --lun=0 2>&1 | grep -cE '^\s+\w+.*:.*Offset' | sed 's/^/  lun0 parts=/'
E printgpt --lun=4 2>&1 | grep -E '^\s*(boot_a|boot_b):' | sed 's/^/  /'

log 'step 6: erase the data side (not optional, see the header)'
for p in userdata metadata misc; do
    log "  $p: $(E e $p --lun=0 2>&1 | tail -1)"
done

log 'step 7: reset'
timeout 90 $EDL reset 2>&1 | tail -1
log 'EDL_RESTORE_DONE - the first Android boot takes a couple of minutes; ADB is off until you enable USB debugging'
