#!/bin/sh
# SPDX-License-Identifier: MIT
# Converge the running TB320FC tablet onto what system_files/ says, and keep it that way.
#
# Two separate reasons this exists (PROGRESS.md A185):
#   * An in-place /usr edit on an ostree deployment survives a reboot but not a rollback or
#     any update that composes a new deployment, so board-side fixes are staged in the
#     stateroot var (/var/usrlocal/lib/tb320fc-usroverlay/files) and tb320fc-usr-overlay
#     replays them into /usr on every boot. This script writes the stage AND applies it to
#     the live deployment.
#   * Bring-up left behind copies that outrank the image: helpers in /usr/local/libexec,
#     unit files directly in /etc/systemd/system, and ExecStart drop-ins pointing at those
#     copies. They pin stale code (a unit kept running AUDIO-v2 while /usr had v3) and they
#     are invisible to the image. This script removes exactly those.
#
# Everything pushed comes from system_files/, so the board never ends up holding something
# the next image does not carry.
#
#   BOARD_PASSWORD=armada sh devices/lenovo-tb320fc/usr-overlay/push.sh 192.168.31.83
# Key-auth (root, or a user with passwordless sudo) needs no BOARD_PASSWORD.
set -eu

IP=${1:?usage: push.sh <board-ip> [ssh-user]}
USER=${2:-armada}
REPO=$(cd -- "$(dirname -- "$0")/../../.." && pwd)

HELPERS="
usr/libexec/tb320fc/audio
usr/libexec/tb320fc/power
usr/libexec/tb320fc/input
usr/libexec/tb320fc/modload
usr/libexec/tb320fc/modules-tree
usr/libexec/tb320fc/usr-overlay
usr/libexec/tb320fc/legacy-off
usr/libexec/tb320fc/board-check
usr/libexec/tb320fc/wifi
usr/libexec/tb320fc/wifi-mac
usr/libexec/tb320fc/wifi-mac-sync
usr/libexec/tb320fc/touch-watch
usr/libexec/tb320fc/touch-revive
usr/libexec/tb320fc/slot-attrs
"
UNITS="
usr/lib/systemd/system/tb320fc-modules-tree.service
usr/lib/systemd/system/tb320fc-usr-overlay.service
usr/lib/systemd/system/tb320fc-legacy-off.service
usr/lib/systemd/system/tb320fc-input.service
usr/lib/systemd/system/tb320fc-wifi-mac.service
"
CONFS="
etc/tb320fc/audio.conf
etc/tb320fc/legacy-off.conf
etc/tb320fc/wifi.conf
etc/tb320fc/touch.conf
etc/tb320fc/power.conf
"
# Files the image already carries but that this board needs a newer copy of, together
# with the data files they read: a device-quirks change is only useful on the next boot
# if the WirePlumber drop-in it installs is staged alongside it. tb320fc-usr-overlay
# runs Before=sysinit.target and armada-device-quirks runs After=sysinit.target, so the
# replayed script is the one that runs in the same boot.
ARMADA_DATA="
usr/libexec/armada/device-quirks
usr/lib/armada/wireplumber/lenovo-tb320fc-speakers.conf
"
FILES="$HELPERS $UNITS $CONFS $ARMADA_DATA"
# The /usr/local copies are what the retired drop-ins pointed at. They stay executable by
# the resolver fallback, so a stale one would silently win over a missing /usr helper;
# renaming them keeps the rollback available without keeping the trap.
STALE="/usr/local/libexec/tb320fc/audio /usr/local/libexec/tb320fc/power /usr/local/libexec/tb320fc/input /usr/local/libexec/tb320fc/modload /usr/local/libexec/tb320fc/modules-tree"
# Units that must be enabled; drop-ins and /etc copies matching these names are removed.
ARM="tb320fc-modules-tree.service tb320fc-usr-overlay.service tb320fc-legacy-off.service tb320fc-input.service tb320fc-audio.service tb320fc-power.service tb320fc-wifi.service tb320fc-wifi-mac.service tb320fc-touch.service"
# Workarounds that the fixed helpers replace: they point ExecStart at /usr/local copies.
HACKS="/etc/systemd/system/tb320fc-audio.service.d /etc/systemd/system/tb320fc-power.service.d"

tmp=$(mktemp)
script=$(mktemp)
trap 'rm -f "$tmp" "$script"' EXIT
( cd "$REPO/system_files" && tar -cf "$tmp" $FILES )
echo "payload $(wc -c < "$tmp") bytes -> $USER@$IP"

if [ -n "${BOARD_PASSWORD:-}" ] ; then
	SSH="sshpass -p ${BOARD_PASSWORD} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${IP}"
else
	SSH="ssh -o StrictHostKeyChecking=no ${USER}@${IP}"
fi

cat > "$script" <<REMOTE
set -eu
STAGE=/var/usrlocal/lib/tb320fc-usroverlay/files
TAR=/tmp/tb320fc-push.tar
ARM="$ARM"
HACKS="$HACKS"
STALE="$STALE"
[ -s "\$TAR" ] || { echo "PUSH FAIL no payload at \$TAR"; exit 1; }

mkdir -p "\$STAGE"
tar -xf "\$TAR" -C "\$STAGE"
# A tarball built on Windows carries no exec bit; the stage is what systemd units exec.
find "\$STAGE" -type f -path '*/libexec/*' -exec chmod 755 {} +
find "\$STAGE" -type f \( -name '*.service' -o -name '*.conf' \) -exec chmod 644 {} +
echo "PUSH staged:"
find "\$STAGE" -type f | sort

# Replay the stage into the running deployment. Run the STAGED helper when it differs from
# the live one: a shell keeps reading a script it overwrites, and an older live copy has no
# guard against that.
live=/usr/libexec/tb320fc/usr-overlay
staged=\$STAGE/usr/libexec/tb320fc/usr-overlay
if [ -f "\$staged" ] && { [ ! -f "\$live" ] || ! cmp -s "\$staged" "\$live" ; } ; then
	echo "PUSH replay via staged helper (live copy is behind)"
	sh "\$staged"
else
	sh "\$live"
fi

# Retire the bring-up leftovers that outrank the image, then re-arm every unit so the
# wants symlinks point at /usr/lib again instead of a deleted /etc copy.
for d in \$HACKS; do
	[ -d "\$d" ] || continue
	mv "\$d" "\$d.retired-\$(date +%Y%m%d-%H%M%S)" 2>/dev/null || rm -rf "\$d"
	echo "PUSH retired drop-in dir \$d"
done
mkdir -p /var/lib/tb320fc/units
for u in \$ARM; do
	[ -f "/etc/systemd/system/\$u" ] || continue
	mv "/etc/systemd/system/\$u" "/var/lib/tb320fc/units/\$u.etcbak" 2>/dev/null \\
		|| rm -f "/etc/systemd/system/\$u"
	echo "PUSH moved /etc copy aside: \$u"
done
systemctl daemon-reload
for u in \$ARM; do
	systemctl enable "\$u" >/dev/null 2>&1 || echo "PUSH WARN enable \$u"
done
systemctl daemon-reload

for f in \$STALE; do
	[ -f "\$f" ] || continue
	cmp -s "\$f" "/usr/libexec/tb320fc/\$(basename \$f)" 2>/dev/null && continue
	mv "\$f" "\$f.stale-\$(date +%Y%m%d-%H%M%S)" 2>/dev/null && echo "PUSH stale copy retired: \$f"
done

sh /usr/libexec/tb320fc/legacy-off

echo "PUSH verify:"
printf '  unit-state'
for u in y700-audio.service y700-power.service tb320fc-legacy-off.service tb320fc-audio.service tb320fc-input.service tb320fc-usr-overlay.service; do
	printf ' %s=%s' "\$u" "\$(systemctl is-enabled "\$u" 2>/dev/null || echo -)"
done
echo
for u in tb320fc-audio.service tb320fc-power.service tb320fc-input.service tb320fc-usr-overlay.service tb320fc-modules-tree.service; do
	printf '  exec %s -> %s\n' "\$u" "\$(systemctl show "\$u" -p ExecStart --value | tr -d '\\t')"
done
ls -l /usr/libexec/tb320fc/ | sed 's/^/  /'
for s in SPK1 SPK2 ; do
	printf '  %s amp=%s digvol=%s\n' "\$s" \\
		"\$(amixer -c0 cget "name=\${s} AMP Enable Switch" 2>/dev/null | sed -n 's/.*: values=//p')" \\
		"\$(amixer -c0 cget "name=\${s} Digital PCM Volume" 2>/dev/null | sed -n 's/.*: values=//p')"
done
rm -f "\$TAR"
REMOTE

$SSH "cat > /tmp/tb320fc-push.tar" < "$tmp"
$SSH "cat > /tmp/tb320fc-push.sh" < "$script"
if [ -n "${BOARD_PASSWORD:-}" ] ; then
	printf '%s\n' "$BOARD_PASSWORD" | $SSH "sudo -S -p '' sh /tmp/tb320fc-push.sh"
else
	$SSH "sh /tmp/tb320fc-push.sh"
fi
$SSH "rm -f /tmp/tb320fc-push.sh" || true
