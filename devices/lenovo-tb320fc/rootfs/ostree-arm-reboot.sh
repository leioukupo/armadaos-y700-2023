#!/usr/bin/env bash
# Turn the composed OSTree root on (or off) and reboot the tablet, in the one
# order that is safe on this board (PROGRESS.md A219/A220).
#
#   ostree-arm-reboot.sh          marker=yes, re-pin boot_a, reboot -> composed root
#   ostree-arm-reboot.sh --flat   marker=no,  re-pin boot_a, reboot -> flat root
#   ostree-arm-reboot.sh --show   report what stage-1 will act on, change nothing
#
# The marker (/etc/armada/ostree-boot) is what armada-ostree-stage1.sh gates on at
# the very start of the next boot; the boot pair has to be back at a fresh prio 15
# before that boot, because XBL takes 8 off the high side per attempt and a payload
# slot parked at 2 comes back on fastboot instead of booting. Marker and slot pin
# therefore belong to the same action as the reboot: split them and the board ends
# up either flat when a composed root was wanted, or in fastboot.
#
# Two bugs this closes, both hit on HA1WZJJ5:
#   * the marker was written through sudo but `systemctl reboot` was left running as
#     the calling user, so polkit refused it ("Call to Reboot failed: Access denied
#     as the requested operation requires interactive authentication") and the board
#     stayed up with the switch already armed.
#   * `setsid nohup sh -c 'sleep 5; systemctl reboot' &` never fires over ssh.
#     setsid changes the POSIX session but leaves the process in sshd's session
#     cgroup, and systemd kills that whole scope when the connection drops.
#     systemd-run puts the job in the system scope, where it survives, and leaves a
#     unit that can be listed before the session goes away.
#
# The reboot step is replaceable so the contract is testable without a board:
#   ARMADA_OSTREE_REBOOT_CMD='echo would reboot'
set -uo pipefail

marker=${ARMADA_OSTREE_MARKER:-/etc/armada/ostree-boot}
slot_pin=${ARMADA_OSTREE_SLOT_PIN:-/usr/libexec/tb320fc/slot-pin}
delay=${ARMADA_OSTREE_REBOOT_DELAY:-6}
reboot_cmd=${ARMADA_OSTREE_REBOOT_CMD:-}
state=${ARMADA_OSTREE_STATE:-}

want=yes
reboot=1
for a in "$@"; do
    case "$a" in
        --flat) want=no ;;
        --yes) want=yes ;;
        --show) reboot=0 ;;
        *)
            printf 'ostree-arm-reboot: unknown argument [%s]\n' "$a" >&2
            printf 'usage: ostree-arm-reboot.sh [--flat|--yes] [--show]\n' >&2
            exit 2
            ;;
    esac
done

# One privilege transition, not one per step: a half-rooted run is what armed the
# marker and then failed to reboot.
if [ "$(id -u)" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        printf 'ostree-arm-reboot: needs root, prime the credential first:\n' >&2
        printf '  echo armada | sudo -S -p "" true\n' >&2
        exit 1
    fi
    exec sudo -n env \
        ARMADA_OSTREE_MARKER="$marker" ARMADA_OSTREE_STATE="$state" \
        ARMADA_OSTREE_SLOT_PIN="$slot_pin" ARMADA_OSTREE_REBOOT_DELAY="$delay" \
        ARMADA_OSTREE_REBOOT_CMD="$reboot_cmd" \
        "$0" "$@"
fi

if [ ! -f "$marker" ]; then
    printf 'ostree-arm-reboot: no %s - stage-1 is not installed on this root\n' "$marker" >&2
    printf '  adopt the flat root first: devices/lenovo-tb320fc/rootfs/adopt-run-board.sh --go\n' >&2
    exit 1
fi

# stage-1 keeps its log and kill switch on the physical root: that is /armada-ostree
# while the flat root is booted, and /sysroot/armada-ostree from inside a composed one.
if [ -z "$state" ]; then
    if [ -d /armada-ostree ]; then
        state=/armada-ostree
    elif [ -d /sysroot/armada-ostree ]; then
        state=/sysroot/armada-ostree
    else
        state=/armada-ostree
    fi
fi

printf 'marker  before=[%s] file=%s\n' "$(tr -d ' \t\r\n' <"$marker")" "$marker"
printf 'state   dir=%s files=[%s]\n' "$state" "$(ls "$state" 2>/dev/null | tr '\n' ' ')"
if [ -e "$state/attempt" ] && [ ! -e "$state/confirmed" ]; then
    printf 'warn    an attempt with no confirmation: stage-1 counts a failure, sets the marker to no and boots flat\n'
fi

if [ "$reboot" = 0 ]; then
    printf 'SHOW    would set marker=[%s]; nothing changed, no reboot scheduled\n' "$want"
    exit 0
fi

printf '%s\n' "$want" >"$marker" || {
    printf 'ostree-arm-reboot: cannot write %s (is / mounted rw?)\n' "$marker" >&2
    exit 1
}
printf 'marker  after =[%s]\n' "$(tr -d ' \t\r\n' <"$marker")"

if [ -x "$slot_pin" ]; then
    "$slot_pin" 2>&1 | tail -3
else
    printf 'warn    no executable %s - the boot pair is not re-pinned\n' "$slot_pin" >&2
fi
sync -f "$marker" 2>/dev/null || sync

if [ -n "$reboot_cmd" ]; then
    printf 'reboot  via ARMADA_OSTREE_REBOOT_CMD\n'
    if ! sh -c "$reboot_cmd"; then
        printf 'ostree-arm-reboot: the reboot command failed; marker stays [%s]\n' "$want" >&2
        exit 1
    fi
    printf 'ARMED marker=[%s]\n' "$want"
    exit 0
fi

systemd-run --quiet --collect --on-active="${delay}s" /usr/bin/systemctl reboot
if systemctl list-units --no-pager 'run-*' 2>/dev/null | grep -q 'systemctl reboot'; then
    printf 'ARMED marker=[%s] reboot=scheduled in %ss\n' "$want" "$delay"
else
    printf 'ostree-arm-reboot: marker is [%s] but no reboot timer is visible\n' "$want" >&2
    printf '  check systemd-run, or reboot by hand now that the marker is set\n' >&2
    exit 1
fi
