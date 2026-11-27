#!/bin/bash
# TB320FC soft-brick rescue, corrected version.
#
# Root cause of the brick: install/gpt-slice-pin.py PIN=b marked every *_a partition unbootable
# (attrs 0x7b -> 0xfb) and every *_b bootable. The Lenovo EDL rom writes real data only into _a
# (rawprogram4.xml has filename="" for uefi_b/tz_b/abl_b/boot_b/devcfg_b), so XBL loaded zeroed
# _b firmware and crashed in XBL itself -> PBL crashdump (05c6:900e), which is read-only
# (loader upload -> Sahara error 0x93011004, command mode -> NAK). No ABL means no fastboot,
# no recovery, and volume keys are not an EDL trigger on this board.
#
# The fix is 11 sectors on LUN4, taken from the pre-pin dumps:
#   prim4.bin  = LBA0..5   (protective MBR + header@1 + entries@2..4)
#   back4.bin  = LBA1572859..1572863 (backup entries + header @ alt4=1572863)
# Note ws must start at LBA0 for prim4.bin -- starting at LBA1 would overwrite the GPT header
# with MBR bytes.
cd "$(dirname "$0")" || exit 1
PY=${PY:-/srv/y700/edlvenv/bin/python}
L=${LOADER:-/srv/y700/firehose/xbl_s_devprg_ns.melf}
BAK=${BAK:-$(dirname "$0")/gptbak}
LOG=${LOG:-/tmp/rescue_gpt.log}
ALT4_BACK_START=1572859
DURATION=${DURATION:-1800}
CYCLE=${CYCLE:-0}
END=$(( $(date +%s) + DURATION ))
prev=""

log() { echo "$(date +%H:%M:%S) $*" >> $LOG; }

restore_gpt() {
    log "EDL(9008) seen -> sanity read of LUN4"
    $PY edl.py --loader=$L --memory=ufshcd rs 0 6 /tmp/chk_prim4.bin --lun=4 >> $LOG 2>&1
    if ! dd if=/tmp/chk_prim4.bin bs=4096 skip=1 count=1 status=none 2>/dev/null | grep -q 'EFI PART'; then
        log "ABORT: LUN4 read-back has no GPT header (not in firehose/UFS mode), not writing"
        return 1
    fi
    if cmp -s /tmp/chk_prim4.bin $BAK/prim4.bin; then
        log "ALREADY_RESTORED primary matches pre-pin dump"
    else
        log "writing prim4.bin @LBA0 and back4.bin @LBA$ALT4_BACK_START"
        $PY edl.py --loader=$L --memory=ufshcd ws 0 $BAK/prim4.bin --lun=4 >> $LOG 2>&1
        $PY edl.py --loader=$L --memory=ufshcd ws $ALT4_BACK_START $BAK/back4.bin --lun=4 >> $LOG 2>&1
        $PY edl.py --loader=$L --memory=ufshcd rs 0 6 /tmp/ok_prim4.bin --lun=4 >> $LOG 2>&1
        $PY edl.py --loader=$L --memory=ufshcd rs $ALT4_BACK_START 5 /tmp/ok_back4.bin --lun=4 >> $LOG 2>&1
        cmp -s /tmp/ok_prim4.bin $BAK/prim4.bin && log "VERIFY_OK primary" || log "VERIFY_FAIL primary"
        cmp -s /tmp/ok_back4.bin $BAK/back4.bin && log "VERIFY_OK backup" || log "VERIFY_FAIL backup"
    fi
    $PY edl.py --loader=$L --memory=ufshcd printgpt --lun=4 2>&1 | grep -E 'boot_a|boot_b' >> $LOG
    $PY edl.py --loader=$L reset >> $LOG 2>&1
    log "FIX_DONE_EDL"
    return 0
}

fastboot_fix() {
    log "fastboot(d00d) seen -> --set-active=a"
    fastboot devices >> $LOG 2>&1
    fastboot --set-active=a >> $LOG 2>&1
    fastboot getvar current-slot >> $LOG 2>&1
    fastboot reboot >> $LOG 2>&1
    log "FIX_DONE_FASTBOOT"
}

while [ $(date +%s) -lt $END ]; do
    cur=$(lsusb | grep -ioE '05c6:9[0-9a-f]{3}|18d1:d00d|17ef:[0-9a-f]{4}' | sort -u | tr '\n' ' ')
    if [ "$cur" != "$prev" ]; then
        log "usb: ${cur:-none}"
        prev="$cur"
    fi
    case "$cur" in
        *9008*) restore_gpt && exit 0;;
    esac
    case "$cur" in
        *d00d*) fastboot_fix; exit 0;;
    esac
    if [ "$CYCLE" = "1" ]; then
        # keep re-arming boot attempts so a held volume key is re-sampled by PBL
        timeout 25 $PY krash_cycle.py >> $LOG 2>&1
    fi
    sleep 1
done
log "RESCUE_TIMEOUT after ${DURATION}s"
exit 1
