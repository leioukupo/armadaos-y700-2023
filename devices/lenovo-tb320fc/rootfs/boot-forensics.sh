#!/bin/sh
# SPDX-License-Identifier: MIT
# TB320FC boot-chain forensic snapshot (PROGRESS.md A207).
#
# This tablet has no log channel that survives a failed boot: ABL/XBL leave nothing
# readable behind (logfs/logdump/qmcs are all empty on HA1WZJJ5), the payload kernel
# has no wired-out serial console, and ArmadaOS over USB has neither adb nor device
# enumeration. So the record is written into the linuxroot itself - the same ext4 we
# can dump over EDL in a few minutes and open with debugfs offline - and, when an
# upload URL is given, pushed straight to the build host while the system is still up.
#
# Read-only except for the output file. Safe to run repeatedly; each run appends one
# block, so the history of "boot N attrs" vs "boot N+1 attrs" lands in one file.
#
#   boot-forensics.sh
#   TB320FC_BOOTCHECK_UPLOAD=http://192.168.31.4:8793/bootcheck.txt boot-forensics.sh
TB320FC_TAG=TB320FC-BOOTCHECK-v1
OUT=${TB320FC_BOOTCHECK_OUT:-/var/usrlocal/log/tb320fc-bootcheck.txt}
UP=${TB320FC_BOOTCHECK_UPLOAD:-}
EXEC=$(dirname "$0")
SLOT_ATTRS="$EXEC/slot-attrs"
[ -x "$SLOT_ATTRS" ] || SLOT_ATTRS=/usr/libexec/tb320fc/slot-attrs
[ -x "$SLOT_ATTRS" ] || SLOT_ATTRS=/usr/local/libexec/tb320fc/slot-attrs

report() {
	echo "=== ${TB320FC_TAG} kernel=$(uname -r) boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) $(date -u +%FT%TZ)"
	echo "--- uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"

	echo "--- units (enabled / load / last status)"
	for u in tb320fc-misc-clear tb320fc-slot-pin tb320fc-touch tb320fc-audio tb320fc-wifi; do
		printf '%s ' "$u"
		systemctl is-enabled "$u.service" 2>&1
		systemctl show "$u.service" -p LoadState,ActiveState,SubState,ExecMainStartTimestamp,ExecMainStatus 2>/dev/null |
			tr '\n' ' '
		echo
	done

	echo "--- misc node discovery (what misc-clear can see at shutdown)"
	ls -l /dev/disk/by-partlabel/misc /dev/block/by-name/misc 2>&1
	dev=""
	for cand in /dev/disk/by-partlabel/misc /dev/block/by-name/misc; do
		[ -e "$cand" ] && { dev=$cand; break; }
	done
	if [ -n "$dev" ]; then
		echo "--- misc first 32 bytes of $dev (offset 0 and offset 8 are the boot requests)"
		dd if="$dev" bs=32 count=1 2>/dev/null | od -An -tx1 -c
		echo "--- misc 0x8000 vendor record"
		dd if="$dev" bs=1 skip=32768 count=16 2>/dev/null | od -An -tx1
	else
		echo "no misc partlabel node found: the shutdown hook would have skipped"
	fi

	echo "--- GPT slot attributes"
	if [ -x "$SLOT_ATTRS" ]; then
		"$SLOT_ATTRS" report 2>&1 | grep -E '^(boot_a|boot_b|abl_a|abl_b|uefi_a|uefi_b|linuxroot|userdata)|priority|disk|LU ' | head -20
	else
		echo "slot-attrs helper not installed"
	fi

	echo "--- journal: this boot"
	journalctl -b 0 --no-pager -u tb320fc-misc-clear.service -u tb320fc-slot-pin.service 2>&1 | tail -25
	echo "--- journal: previous boot (needs /var/log/journal)"
	journalctl -b -1 --no-pager -u tb320fc-misc-clear.service -u tb320fc-slot-pin.service 2>&1 | tail -25
	ls -l /var/log/journal 2>&1 | head -3

	echo "--- battery (ABL refuses to boot a payload at low charge)"
	for f in /sys/class/power_supply/*/capacity /sys/class/power_supply/*/capacity_level \
	         /sys/class/power_supply/*/present /sys/class/power_supply/*/status; do
		[ -e "$f" ] && printf '%s = %s\n' "$f" "$(cat "$f" 2>/dev/null)"
	done

	echo "--- block devices (which LU holds misc/linuxroot)"
	ls -l /dev/disk/by-partlabel 2>&1 | head -12
	echo
}

mkdir -p "$(dirname "$OUT")" 2>/dev/null
tmp="${OUT}.new"
report > "$tmp" 2>&1
cat "$tmp" >> "$OUT"
rm -f "$tmp"
echo "${TB320FC_TAG} done out=${OUT} bytes=$(wc -c < "$OUT" 2>/dev/null)"

if [ -n "$UP" ] ; then
	if command -v curl >/dev/null 2>&1 ; then
		curl -sS -m 60 -T "$OUT" "$UP" && echo "${TB320FC_TAG} uploaded ${UP}"
	else
		echo "${TB320FC_TAG} no curl, upload skipped"
	fi
fi
