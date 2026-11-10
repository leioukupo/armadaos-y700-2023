#!/bin/sh
# A90: turn the A89 weston success into a usable session, and read the distro's
# own session units while we have the root mounted.
#
# A89 proved: weston 15.0.1 drm backend on the A88 simpledrm card, GL via Mesa
# llvmpipe, output Unknown-1 1600x2560@60, NT36523N tagged as Touchscreen,
# weston-keyboard + weston-desktop-shell launched, rc=124 (ran the whole
# window) and the panel really went blue.
#
# A90 changes three things, all still inside /etc and /usr/local:
#  * rotate the logical output to landscape - the panel is natively 1600x2560
#    portrait, the tablet is a landscape device.
#  * put clients on the session (weston-tablet draws every touch point, so touch
#    becomes visible evidence; weston-terminal gives something to tap and type).
#  * lengthen the window to 10 minutes, and always put fbcon back afterwards so
#    the panel is never permanently lost.
# Everything goes to the card. As a free side effect the patch phase copies the
# distro session units (armada-session-default, splash, gamescope) off the UFS
# root, which the truncated armada-root.img on this board cannot show us.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A90-PATCH"
CARD=/mnt/card
OUT=$CARD/y700-a90-patch.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac
echo "=== Y700-A90 session patch up=$(UP) ===" > "$OUT" 2>/dev/null
U "rootdev=$RD"
[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; exit 1; }

# What the distro itself wants to run - read only, nothing here is executed.
mkdir -p /mnt/ufs 2>/dev/null
mount -t ext4 -o ro /dev/sda16 /mnt/ufs 2>/dev/null
if [ -d /mnt/ufs/usr ]; then
	for u in armada-session-default.service armada-splash-early.service armada-control.service armada-powerd.service armada-input-calibration.service armada-waydroid-input.service; do
		U "--- unit $u ---"
		cat /mnt/ufs/usr/lib/systemd/system/$u 2>&1 | head -30 >> "$OUT" 2>&1
	done
	U "--- default target ---"; readlink /mnt/ufs/etc/systemd/system/default.target 2>&1 >> "$OUT"
	U "--- graphical.target.wants ---"; ls -l /mnt/ufs/usr/lib/systemd/system/graphical.target.wants 2>&1 >> "$OUT"
	U "--- session bins ---"; ls -l /mnt/ufs/usr/bin/gamescope-session-plus /mnt/ufs/usr/bin/armada-nested-desktop 2>&1 >> "$OUT"
	U "--- gamescope-session-plus head ---"; head -40 /mnt/ufs/usr/bin/gamescope-session-plus 2>&1 >> "$OUT"
	U "--- libexec armada ---"; ls -l /mnt/ufs/usr/libexec/armada 2>&1 | head -20 >> "$OUT"
	U "--- wl sessions ---"; ls -l /mnt/ufs/usr/share/wayland-sessions 2>&1 >> "$OUT"
fi
umount /mnt/ufs 2>/dev/null

MSG=$(mount -t ext4 -o rw /dev/sda16 /mnt/ufs 2>&1)
MR=$?
U "remount rw rc=$MR msg=$MSG"
[ "$MR" = "0" ] || { m "REFUSE cannot mount sda16 rw"; exit 1; }
R=/mnt/ufs
[ -x "$R/usr/bin/weston" ] || { m "REFUSE no weston in root"; umount /mnt/ufs; exit 1; }
mkdir -p "$R/usr/local/sbin" "$R/etc/xdg/weston" "$R/etc/systemd/system/multi-user.target.wants"

cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A90: a weston session you can actually touch. Log lives in /tmp and is mirrored
# to the card on our own mount point, so the A87b diag unit cannot pull it away.
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
T=/tmp/y700-a90-desktop.txt
mirror() {
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a90-desktop.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A90 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A90 $*" >> "$T" 2>/dev/null
	mirror
}
RUN=/run/y700-wayland
WINDOW=${Y700_WINDOW:-600}
echo "===== Y700-A90 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} window=$WINDOW =====" >> "$T" 2>&1
{
	echo "-- dri --"; ls -l /dev/dri 2>&1
	for f in /sys/class/drm/card0*/modes; do echo "-- modes $f --"; cat "$f" 2>&1; done
	echo "-- backlight --"; for d in /sys/class/backlight/*; do echo "$d max=$(cat $d/max_brightness 2>&1) cur=$(cat $d/brightness 2>&1)"; done
	echo "-- input --"; ls -l /dev/input 2>&1
	echo "-- vtcon --"; cat /sys/class/vtconsole/vtcon*/name 2>&1
} >> "$T" 2>&1
mirror

FB=""
for b in /sys/class/vtconsole/vtcon1/bind; do
	[ -e "$b" ] || continue
	echo 0 > "$b" 2>/dev/null && FB="$b"
done
m "fbcon off via ${FB:-nothing}"

mkdir -p $RUN
chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1

m "weston start window=${WINDOW}s"
/usr/bin/weston --backend=drm >> "$T" 2>&1 &
WP=$!
i=0
while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 25 ]; do sleep 1; i=$((i + 1)); done
m "wayland socket after ${i}s: $(ls $RUN 2>&1 | tr '\n' ' ')"
export WAYLAND_DISPLAY=wayland-1
if [ -S $RUN/wayland-1 ]; then
	timeout 30 /usr/bin/weston-tablet >> "$T" 2>&1 &
	timeout 180 /usr/bin/weston-terminal >> "$T" 2>&1 &
	m "clients launched weston-tablet(30s) weston-terminal(180s)"
	sleep 10
	wlr-randr >> "$T" 2>&1
	m "wlr-randr dumped (check transform/mode)"
	mirror
else
	m "no wayland socket, clients skipped"
fi

end=$(( $(cut -d. -f1 /proc/uptime) + WINDOW ))
while [ -d /proc/$WP ] && [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do sleep 5; done
if [ -d /proc/$WP ]; then
	m "window elapsed, stopping weston pid=$WP"
	kill -TERM $WP 2>/dev/null
	sleep 4
	kill -KILL $WP 2>/dev/null
else
	m "weston exited early pid=$WP up=$(cut -d. -f1 /proc/uptime)"
fi
wait $WP 2>/dev/null
m "weston gone, fbcon back, PULL THE CARD NOW"
[ -n "$FB" ] && echo 1 > "$FB" 2>/dev/null
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v3 installed"

cat > "$R/etc/xdg/weston/weston.ini" <<'INI'
# A90: the panel is a simple-framebuffer with one fixed mode, 1600x2560 mounted
# portrait. The tablet is held landscape, so rotate the logical output.
[core]
xkb-layout=us

[output]
name=Unknown-1
transform=270

[shell]
background-type=uniform-color
background-color=0x204080ff
panel-position=bottom

[libinput]
enable-tap=true
INI
U "weston.ini v3 installed (transform=270, panel bottom, tap)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A90 weston session on simpledrm
Wants=dev-dri-card0.device
After=dev-dri-card0.device seatd.service systemd-user-sessions.service

[Service]
Type=simple
TimeoutStartSec=1800
StandardOutput=journal
StandardError=journal
ExecStart=/usr/local/sbin/y700-desktop.sh

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../y700-desktop.service "$R/etc/systemd/system/multi-user.target.wants/y700-desktop.service"
U "desktop unit v3 wanted by multi-user.target"

sync
umount /mnt/ufs 2>/dev/null || m "umount busy"
echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt"
sync
U "marker y700-ufs.txt=$(cat $CARD/y700-ufs.txt)"
m "SESSION INSTALLED, rebooting in 6s - keep the card in"
sleep 6
busybox reboot -f
m "reboot -f did not happen"
sleep 300
exit 0