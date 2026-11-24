#!/bin/sh
# Decide whether the composed OSTree root is a machine we can still reach.
#
# This board has no serial console, no TF card and nothing outside UFS can read
# its root, so stage-1 writes an attempt file on the physical root before it moves
# any mount and this unit turns that attempt into a confirmation. An attempt that
# is never confirmed counts as a dead composed boot and the next boot stays flat.
#
# The criterion has to mean "we can get in", not "NetworkManager was fast": on
# this hardware ath11k only probes ~150 s into the boot and a Wi-Fi scan can hang
# for tens of minutes, so checking for a route once (or only in the first couple
# of minutes) reports a perfectly healthy desktop as dead. So all three of these
# confirm, and the reason is logged:
#   route          a usable default route
#   sshd+addr      sshd running with a global address - we can get in
#   system:<state> systemd finished and the display manager is up - the user is
#                  looking at the desktop, and fastboot/adb remain the last resort
#
# It lives in a file rather than in ExecStart because systemd expands "$name" in
# ExecStart, which silently ate the loop counter of the first version.
set -u
state=/sysroot/armada-ostree
logf=$state/boot.log
tries=${ARMADA_OSTREE_CONFIRM_TRIES:-96}
sleep_s=${ARMADA_OSTREE_CONFIRM_SLEEP:-5}

log() { printf 'armada-ostree-confirm %s\n' "$*" >>"$logf" 2>/dev/null; }

# First make the running deployment legible to ostree/bootc: without a bootloader
# spec that names it, "ostree admin status" and "bootc status" fail and the Armada
# tools show "Could not read OS state" even though the composed root is healthy.
/usr/lib/armada/armada-ostree-bootlink.sh >>"$logf" 2>&1

why=none
runstate=unknown
i=0
while [ "$i" -lt "$tries" ]; do
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
        why=route
        break
    fi
    if systemctl is-active --quiet sshd &&
       ip -4 -o addr show scope global 2>/dev/null | grep -q '[0-9]'; then
        why=sshd+addr
        break
    fi
    runstate=$(systemctl is-system-running 2>/dev/null)
    case "$runstate" in
        running | degraded)
            if systemctl is-active --quiet display-manager; then
                why=system:$runstate
                break
            fi
            ;;
    esac
    sleep "$sleep_s"
    i=$((i + 1))
done

ifaces=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}' | tr '\n' ',')
log "$why (ifaces=$ifaces state=$runstate waited=$((i * sleep_s))s)"

# Whatever the answer, leave the tail of this boot's journal on the physical root:
# a composed root that comes up without a route still has to be diagnosable from
# the flat boot that follows it. Same for what ostree and bootc make of the
# deployment, which is what the Armada tools ask for.
journalctl -b --no-pager -p warning 2>/dev/null | tail -200 >"$state/journal-last.txt" 2>/dev/null
ostree admin status >"$state/ostree-status.txt" 2>&1
bootc status >"$state/bootc-status.txt" 2>&1

if [ "$why" != none ]; then
    touch "$state/confirmed" 2>/dev/null
    rm -f "$state/failed" 2>/dev/null
fi
exit 0
