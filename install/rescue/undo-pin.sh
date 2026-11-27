#!/bin/sh
# Restore the LUN4 GPT exactly as captured before gpt-slice-pin.py ran.
# prim4.bin starts at LBA0 and holds the protective MBR, hence ws 0 is required.
# Read the table first: a GPT header in the read-back proves we are in firehose/UFS mode,
# not in the read-only crashdump path, where --memory silently dumps DDR instead.
set -e
: ${LOADER:?set LOADER to xbl_s_devprg_ns.melf}
GPT=${GPTDIR:-gptbak}
EDL=${EDL:-edl.py --loader=$LOADER --memory=ufshcd}
$EDL rs 0 6 /tmp/check_prim4.bin --lun=4
dd if=/tmp/check_prim4.bin bs=4096 skip=1 count=1 2>/dev/null | grep -q EFI || exit 1
$EDL ws 0 $GPT/prim4.bin --lun=4
$EDL ws 1572859 $GPT/back4.bin --lun=4
$EDL rs 0 6 /tmp/ok_prim4.bin --lun=4
cmp /tmp/ok_prim4.bin $GPT/prim4.bin
$EDL rs 1572859 5 /tmp/ok_back4.bin --lun=4
cmp /tmp/ok_back4.bin $GPT/back4.bin
edl.py --loader=$LOADER reset
echo GPT_RESTORED_AND_VERIFIED
