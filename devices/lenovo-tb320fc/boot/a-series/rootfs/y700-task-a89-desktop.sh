#!/bin/sh
# A89: put the first compositor on the simpledrm card that A88 produced.
#
# What A87b proved: /dev/dri/card0 exists, fb0 is simpledrmdrmfb, y700fb stood
# down, and systemd is not hung at all - the only pending job was the diag
# script itself. So the panel now has a real KMS device, which is what weston
# and cage need and what the old hand-written fbdev could never give them.
#
# This round stays inside /etc and /usr/local of the UFS root - no reflash:
#  * /usr/local/sbin/y700-desktop.sh  - unbinds fbcon (one writer on the panel),
#    runs weston for 120s, and if weston did not survive the whole window runs
#    cage for 90s as the second opinion. weston 15 has no pixman renderer, so
#    GL comes from Mesa kms_swrast over simpledrm; both are in the installed root.
#  * /etc/xdg/weston/weston.ini       - only the parts we are sure about.
#  * y700-desktop.service             - wanted by multi-user.target, which the
#    A87b report showed is reached moments after the diag job clears.
# Everything it learns (drm nodes, modes, input devices, compositor output) goes
# onto the SD card, so a blind panel still leaves us a full answer.
#
# v2: the A87b diag unit still mounts the card at /mnt/card and umounts it about
# 30s in, which is exactly when this service starts. So the desktop log is kept
# in /tmp and mirrored to the card on our own mount point (/mnt/y700card), which
# the diag unit cannot pull out from under us.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A89-PATCH"
CARD=/mnt/card
OUT=$CARD/y700-a89-patch.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac
echo "=== Y700-A89 v2 desktop patch up=$(UP) ===" > "$OUT" 2>/dev/null
U "rootdev=$RD"
[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; exit 1; }

mkdir -p /mnt/ufs 2>/dev/null
MSG=$(mount -t ext4 -o rw /dev/sda16 /mnt/ufs 2>&1)
MR=$?
U "mount rc=$MR msg=$MSG"
[ "$MR" = "0" ] || { m "REFUSE cannot mount sda16 rw"; exit 1; }
R=/mnt/ufs
[ -x "$R/usr/lib/systemd/systemd" ] || { m "REFUSE no systemd in root"; umount /mnt/ufs; exit 1; }
[ -x "$R/usr/bin/weston" ] || { m "REFUSE no weston in root"; umount /mnt/ufs; exit 1; }
U "weston=$($R/usr/bin/weston --version 2>&1 | busybox head -1) cage=$($R/usr/bin/cage -v 2>&1 | busybox head -1)"

mkdir -p "$R/usr/local/sbin" "$R/etc/xdg/weston" "$R/etc/systemd/system/multi-user.target.wants"

cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A89: first compositor on the A88 simpledrm card. One writer on the panel, and
# the whole session log goes to the SD card because the panel is the thing under
# test - if it never lights up, the card still says why.
C=/mnt/y700card
CARD=""
for d in /dev/disk/by-label/ARMADA /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/mmcblk2p1; do
	[ -b "$d" ] || continue
	if mountpoint -q "$C"; then
		CARD="$d"
	else
		mkdir -p "$C"
		mount -o rw "$d" "$C" 2>/dev/null && CARD="$d"
	fi
	[ -n "$CARD" ] && break
done
# /tmp is the working log; the card copy is a mirror, refreshed after every mark
# so a crash in the middle of weston still leaves a readable answer.
T=/tmp/y700-a89-desktop.txt
m() {
	echo "<3>Y700-A89 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A89 $*" >> "$T" 2>/dev/null
	mirror
}
mirror() {
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a89-desktop.txt" 2>/dev/null
	sync
}
echo "===== Y700-A89 v2 desktop up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} =====" >> "$T" 2>&1
{
	echo "-- dri --"; ls -l /dev/dri 2>&1
	echo "-- drm --"; ls -l /sys/class/drm 2>&1
	for f in /sys/class/drm/card0*/modes; do echo "-- modes $f --"; cat "$f" 2>&1; done
	echo "-- fbcon --"; cat /sys/class/vtconsole/vtcon*/name 2>&1; ls /sys/class/graphics 2>&1
	echo "-- input --"; ls -l /dev/input 2>&1; grep -E "^I:|^N:" /proc/bus/input/devices 2>/dev/null
	echo "-- gl --"; ls /usr/lib64/dri/kms_swrast_dri.so /usr/lib64/dri/swrast_dri.so 2>&1
	echo "-- libweston --"; ls -d /usr/lib64/libweston-* /usr/lib64/weston/*.so 2>&1
	echo "-- dumb/prime probe --"; ls /sys/kernel/debug/dri 2>&1
} >> "$T" 2>&1
mirror

# The panel is one framebuffer: fbcon drawing text and the compositor drawing
# frames into the same memory is a flicker fight, so the text console steps out
# for the duration and is put back at the end.
FB=""
for b in /sys/class/vtconsole/vtcon1/bind; do
	[ -e "$b" ] || continue
	echo 0 > "$b" 2>/dev/null && FB="$b"
done
m "fbcon off via ${FB:-nothing}"

mkdir -p /run/y700-wayland
chmod 700 /run/y700-wayland
export XDG_RUNTIME_DIR=/run/y700-wayland
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1

m "weston start (120s window)"
timeout 120 /usr/bin/weston --backend=drm >> "$T" 2>&1
WR=$?
m "weston rc=$WR (124 means it ran the whole window)"
if [ "$WR" != "124" ]; then
	m "cage start (90s window)"
	timeout 90 /usr/bin/cage >> "$T" 2>&1
	m "cage rc=$?"
fi
m "DONE fbcon back, PULL THE CARD NOW"
[ -n "$FB" ] && echo 1 > "$FB" 2>/dev/null
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script installed"

cat > "$R/etc/xdg/weston/weston.ini" <<'INI'
# A89: the panel is a simple-framebuffer, so there is exactly one fixed mode and
# no mode probing to configure. Keep this file to what is known true.
[core]
xkb-layout=us

[shell]
background-type=uniform
background-color=0x204080ff
INI
U "weston.ini installed"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A89 first compositor on simpledrm
Wants=dev-dri-card0.device
After=dev-dri-card0.device seatd.service systemd-user-sessions.service

[Service]
Type=simple
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal
ExecStart=/usr/local/sbin/y700-desktop.sh

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../y700-desktop.service "$R/etc/systemd/system/multi-user.target.wants/y700-desktop.service"
U "desktop unit installed and wanted by multi-user.target"

# binfmt_misc and rpc_pipefs are not in this kernel; they only add red lines.
for u in proc-sys-fs-binfmt_misc.mount systemd-binfmt.service var-lib-nfs-rpc_pipefs.mount bootc-generic-growpart.service; do
	ln -sf /dev/null "$R/etc/systemd/system/$u"
done
U "masked 4 known-absent units"

sync
umount /mnt/ufs 2>/dev/null || m "umount busy"
echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt"
sync
U "marker y700-ufs.txt=$(cat $CARD/y700-ufs.txt)"
m "PATCHED weston+cage installed, rebooting in 6s - keep the card in"
sleep 6
busybox reboot -f
m "reboot -f did not happen"
sleep 300
exit 0