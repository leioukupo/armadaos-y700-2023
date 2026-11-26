#!/bin/bash
# Tests for system_files/usr/libexec/tb320fc/misc-clear (PROGRESS.md A207).
#
# A reboot issued from ArmadaOS leaves "-bootloader" in the first 16 bytes of the
# 1 MiB misc partition, and ABL then parks the board on the fastboot screen with no
# way back from inside the payload. The helper runs as a shutdown hook and zeroes
# that region. Both directions of getting it wrong are expensive: clear too little
# and the device needs a full EDL restore to boot again, clear too much and it
# destroys the vendor record that lives at 0x8000 in the same partition.
#
# The functional half drives the real helper against a regular-file fixture, so no
# device, systemd, root or UFS is involved.
set -uo pipefail

cd "$(dirname "$0")/.."
TOOL=system_files/usr/libexec/tb320fc/misc-clear
UNIT=system_files/usr/lib/systemd/system/tb320fc-misc-clear.service
CONF=system_files/etc/tb320fc/misc-clear.conf
BUILD=build_files/40-vendor-system-files.sh
PUSH=devices/lenovo-tb320fc/usr-overlay/push.sh

[ -f "$TOOL" ] || { echo "FAIL: $TOOL missing"; exit 1; }
command -v od >/dev/null && command -v dd >/dev/null || { echo 'SKIP: dd and od needed'; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
grep_ok(){ if printf '%s' "$2" | grep -q -- "$1"; then ok "$3"; else bad "$3 (no [$1] in: $(printf '%s' "$2" | tr '\n' ' '))"; fi; }

# ---- static shape: the hook has to run on the way out, not on the way in ----
sh -n "$TOOL" && ok 'helper parses as POSIX sh' || bad 'helper parses as POSIX sh'
[ -f "$UNIT" ] && ok 'ships the shutdown unit' || bad 'ships the shutdown unit'
[ -f "$CONF" ] && ok 'ships the config file' || bad 'ships the config file'
U=$(cat "$UNIT")
grep_ok 'DefaultDependencies=no' "$U" 'unit keeps its own ordering at shutdown'
grep_ok 'Before=shutdown\.target' "$U" 'unit is ordered before shutdown.target'
grep_ok '^ExecStart=/usr/libexec/tb320fc/misc-clear' "$U" 'helper runs from ExecStart of the shutdown transaction'
if printf '%s' "$U" | grep -q '^ExecStop='; then bad 'unit leans on ExecStop again, which never runs for a shutdown.target wants unit'; else ok 'unit does not lean on ExecStop'; fi
grep_ok 'WantedBy=shutdown\.target' "$U" 'unit is pulled in by shutdown.target'
grep_ok 'systemctl enable tb320fc-misc-clear\.service' "$(cat "$BUILD")" 'image build enables the unit'
grep_ok 'misc-clear' "$(cat "$PUSH")" 'push.sh ships the helper'

# ---- fixtures ----
DT=$W/dt
printf 'lenovo,tb320fc\0' > "$DT"
DT_OTHER=$W/dt-other
printf 'qcom,sm8475\0' > "$DT_OTHER"

mk_misc() {
    dd if=/dev/zero of="$1" bs=1024 count=1024 status=none
    printf '%s' '-bootloader' | dd of="$1" bs=1 seek=8 conv=notrunc status=none
    printf '\xab' | dd of="$1" bs=1 seek=32768 conv=notrunc status=none
}
byte() { dd if="$1" bs=1 skip="$2" count=1 status=none | od -An -tx1 | tr -d ' \n'; }
# empty output == the whole 16 KiB request region is zero
dirty() { dd if="$1" bs=1024 count=16 status=none | od -An -v -tx1 | tr -d ' \t\n' | tr -d '0'; }
want_dirty(){ if [ -n "$(dirty "$1")" ]; then ok "$2"; else bad "$2 (request region reads as all zero)"; fi; }
want_clear(){ if [ -z "$(dirty "$1")" ]; then ok "$2"; else bad "$2 (request still holds: $(dd if="$1" bs=1 count=24 status=none | od -An -c | tr -s ' '))"; fi; }

run() { # run <dt> <conf> <dev> ; sets rc/out
    TB320FC_DT_COMPATIBLE="$1" TB320FC_MISC_CLEAR_CONF="$2" TB320FC_MISC_DEV="$3" \
        sh "$TOOL" > "$W/out" 2>&1
    rc=$?; out=$(cat "$W/out")
}

# 1. the real bug: a bootloader request is cleared, the vendor record is left alone
M=$W/misc; mk_misc "$M"
want_dirty "$M" 'fixture starts with a bootloader request'
run "$DT" "$CONF" "$M"
check 'clear exits 0' "$rc" 0
grep_ok 'already_clear=0 written=16' "$out" 'reports one 16 KiB write'
want_clear "$M" 'request region is zero'
check 'vendor record at 0x8000 survives' ab "$(byte "$M" 32768)"

# 2. idempotent: a no-op reboot must not wear the UFS
run "$DT" "$CONF" "$M"
check 'second run exits 0' "$rc" 0
grep_ok 'already_clear=1 written=0' "$out" 'second run writes nothing'

# 3. kill switch
printf 'clear=off\nregion_kib=16\n' > "$W/off.conf"
M=$W/misc3; mk_misc "$M"
run "$DT" "$W/off.conf" "$M"
check 'clear=off exits 0' "$rc" 0
grep_ok 'skip clear=off' "$out" 'kill switch is honoured'
want_dirty "$M" 'clear=off leaves misc alone'

# 4. board gate: other machines touch nothing
M=$W/misc4; mk_misc "$M"
run "$DT_OTHER" "$CONF" "$M"
check 'other board exits 0' "$rc" 0
grep_ok 'skip board-mismatch' "$out" 'board gate skips foreign hardware'
want_dirty "$M" 'other board leaves misc alone'

# 5. an explicit target that is missing is a hard failure, never a silent success
run "$DT" "$CONF" "$W/no-such-partition"
check 'missing override fails' "$rc" 1
grep_ok 'FAIL target-not-block-or-regular' "$out" 'missing explicit target is reported'

# 6. region_kib is respected, so a narrower region cannot eat further into misc
printf 'clear=on\nregion_kib=1\n' > "$W/narrow.conf"
M=$W/misc5; mk_misc "$M"
printf '\xcd' | dd of="$M" bs=1 seek=1500 conv=notrunc status=none
run "$DT" "$W/narrow.conf" "$M"
check 'narrow region exits 0' "$rc" 0
grep_ok 'written=1' "$out" 'reports the configured region size'
check 'byte past the region survives' cd "$(byte "$M" 1500)"
check 'offset 8 cleared inside the 1 KiB window' 00 "$(byte "$M" 8)"

# 7. refusing a region bigger than the target beats writing past the end
printf 'clear=on\nregion_kib=64\n' > "$W/big.conf"
dd if=/dev/zero of="$W/tiny" bs=1 count=64 status=none
run "$DT" "$W/big.conf" "$W/tiny"
check 'oversized region fails' "$rc" 1
grep_ok 'FAIL region-larger-than-target' "$out" 'oversized region is refused'

printf 'TB320FC-MISC-CLEAR-TEST tests=%d pass=%d fail=%d\n' "$((pass+fail))" "$pass" "$fail"
[ "$fail" -eq 0 ]
