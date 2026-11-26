#!/usr/bin/env bash
# ostree-arm-reboot.sh contract (PROGRESS.md A220).
#
# Switching the composed OSTree root on is three steps that only work together:
# write the marker stage-1 gates on, put the Android boot pair back at prio 15,
# and actually reboot. On the tablet two of those failed silently. The marker was
# written as root while `systemctl reboot` ran as the login user, so polkit denied
# it and the board stayed up already armed; and a `setsid nohup sh -c "sleep 5;
# systemctl reboot" &` never fired at all, because setsid leaves the process in
# sshd's session cgroup and systemd kills that scope when ssh disconnects.
#
# The test drives the real script against a marker file in a temp dir, with the
# reboot replaced by ARMADA_OSTREE_REBOOT_CMD, so no board, no systemd and no
# reboot is involved.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/devices/lenovo-tb320fc/rootfs/ostree-arm-reboot.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'ok %s\n' "$*"
}

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
[ -x "$SCRIPT" ] || fail "$SCRIPT is not executable"
bash -n "$SCRIPT" || fail "$SCRIPT does not parse"
ok "the helper exists, is executable and parses"

if [ "$(id -u)" -ne 0 ]; then
    printf 'SKIP: %s needs root to write the marker it exercises\n' "$0"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/etc/armada" "$work/armada-ostree"
marker="$work/etc/armada/ostree-boot"
state="$work/armada-ostree"
printf 'no\n' >"$marker"

pin="$work/slot-pin"
printf '#!/bin/sh\nprintf "TB320FC-SLOT-PIN-v1 stub args=%%s\\n" "$*"\nexit 0\n' >"$pin"
chmod 755 "$pin"

run() {
    ARMADA_OSTREE_MARKER="$marker" ARMADA_OSTREE_STATE="$state" \
        ARMADA_OSTREE_SLOT_PIN="$pin" ARMADA_OSTREE_REBOOT_CMD='echo REBOOT_SCHEDULED' \
        bash "$SCRIPT" "$@"
}

marker_value() { tr -d ' \t\r\n' <"$marker"; }

# ---- --show is read-only -----------------------------------------------------
out="$(run --show)" || fail "--show exited non-zero: $out"
printf '%s\n' "$out" | grep -q 'REBOOT_SCHEDULED' && fail "--show scheduled a reboot"
[ "$(marker_value)" = no ] || fail "--show changed the marker to [$(marker_value)]"
printf '%s\n' "$out" | grep -q 'before=\[no\]' || fail "--show did not report the marker: $out"
printf '%s\n' "$out" | grep -q 'would set marker=\[yes\]' || fail "--show did not say what it would do: $out"
ok "--show reports the state and changes nothing"

# ---- arming writes the marker, re-pins the slot and only then reboots --------
out="$(run)" || fail "arming run exited non-zero: $out"
[ "$(marker_value)" = yes ] || fail "arming left the marker at [$(marker_value)]"
printf '%s\n' "$out" | grep -q 'after =\[yes\]' || fail "arming did not report the new marker: $out"
printf '%s\n' "$out" | grep -q 'SLOT-PIN-v1 stub' || fail "arming skipped the slot pin: $out"
printf '%s\n' "$out" | grep -q 'REBOOT_SCHEDULED' || fail "arming did not reach the reboot: $out"
printf '%s\n' "$out" | grep -q 'ARMED marker=\[yes\]' || fail "arming did not print ARMED: $out"
ok "arming sets the marker, re-pins boot_a and schedules the reboot"

# ---- the arming order is marker -> slot pin -> reboot ------------------------
order="$(printf '%s\n' "$out" | grep -n -e 'after =\[yes\]' -e 'SLOT-PIN-v1 stub' -e 'REBOOT_SCHEDULED' |
    cut -d: -f1 | tr '\n' ' ')"
set -- $order
[ "$#" = 3 ] || fail "expected three ordered lines, got [$order]"
[ "$1" -lt "$2" ] && [ "$2" -lt "$3" ] || fail "wrong arming order: $out"
ok "marker, slot pin and reboot happen in that order"

# ---- --flat disarms without touching the slot pin semantics ------------------
out="$(run --flat)" || fail "--flat exited non-zero: $out"
[ "$(marker_value)" = no ] || fail "--flat left the marker at [$(marker_value)]"
printf '%s\n' "$out" | grep -q 'REBOOT_SCHEDULED' || fail "--flat did not reboot"
ok "--flat arms the fall-back and still reboots"

# ---- a root that never got stage-1 is refused, not half-armed ----------------
mv "$marker" "$marker.hidden"
out="$(run 2>&1)"; rc=$?
mv "$marker.hidden" "$marker"
[ "$rc" = 1 ] || fail "missing marker gave exit $rc, expected 1: $out"
printf '%s\n' "$out" | grep -q 'adopt the flat root first' || fail "missing marker gave no pointer: $out"
ok "a root without stage-1 is refused with a pointer to the adoption"

# ---- the kill switch is visible before the reboot ----------------------------
printf 'stage1\n' >"$state/attempt"
out="$(run --show)" || fail "--show with an open attempt exited non-zero: $out"
printf '%s\n' "$out" | grep -q 'attempt with no confirmation' || fail "open attempt was not warned about: $out"
printf 'stage1\n' >"$state/confirmed"
out="$(run --show)" || fail "--show with a confirmed attempt exited non-zero: $out"
printf '%s\n' "$out" | grep -q 'attempt with no confirmation' && fail "a confirmed attempt still warned"
rm -f "$state/attempt" "$state/confirmed"
ok "an unconfirmed attempt is warned about, a confirmed one is not"

# ---- a failed reboot is reported, and never silently half-armed --------------
out="$(ARMADA_OSTREE_MARKER="$marker" ARMADA_OSTREE_STATE="$state" ARMADA_OSTREE_SLOT_PIN="$pin" \
    ARMADA_OSTREE_REBOOT_CMD='echo boom >&2; exit 3' bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" = 1 ] || fail "a failing reboot command gave exit $rc, expected 1: $out"
printf '%s\n' "$out" | grep -q 'the reboot command failed' || fail "a failing reboot command was not reported: $out"
ok "a failing reboot command exits non-zero instead of looking armed"

# ---- argument handling -------------------------------------------------------
run --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] || fail "an unknown argument gave exit $rc, expected 2"
ok "unknown arguments are rejected"

# ---- the reboot has to survive the ssh session it was scheduled from ---------
# only code counts here: the header comment describes the setsid bug it replaces
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -q 'setsid'; then
    fail "the helper schedules the reboot with setsid again"
fi
grep -q 'systemd-run' "$SCRIPT" || fail "the helper does not schedule the reboot through systemd-run"
grep -q -- '--on-active' "$SCRIPT" || fail "the helper does not delay the reboot with --on-active"
ok "the reboot goes through systemd-run --on-active, not a setsid background job"

printf 'TB320FC-OSTREE-ARM-TEST-OK checks all passed\n'
