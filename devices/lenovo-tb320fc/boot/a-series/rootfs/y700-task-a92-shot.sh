#!/bin/sh
# A91: the A90 session with the one thing A90 got wrong - weston rejected the ini
# transform, so it exited before any output was enabled.
#
# A90 also read the distro's own session units, which turned out to be a
# SteamOS-shaped stack (sddm + gamescope-session-plus + armada-powerd/control),
# and the default target is multi-user.target: the splash unit painted
# "Preparing Armada" and then nothing ever asked for a display. weston at
# multi-user.target is therefore the right place for us to live.
#
# A89 proved: weston 15.0.1 drm backend on the A88 simpledrm card, GL via Mesa
# llvmpipe, output Unknown-1 1600x2560@60, NT36523N tagged as Touchscreen,
# weston-keyboard + weston-desktop-shell launched, rc=124 (ran the whole
# window) and the panel really went blue.
#
# A92 is A91 with three fixes, learned from the A91 round (which worked:
# landscape, panel, terminal, touch all confirmed on the glass):
#  * the weston screenshot is copied to the card, so the panel can be inspected
#    without a camera - weston-screenshooter speaks weston_capture_v1, which the
#    15.0.1 compositor does provide.
#  * the dead RTC is seeded from the card: the PC wrote y700-task.sh with a real
#    clock, so its mtime is a usable wall time.
#  * the backlight boots at 1027/2047 and is raised.
#
# A91 changes three things, all still inside /etc and /usr/local:
#  * rotate the logical output to landscape - the panel is natively 1600x2560
#    portrait, the tablet is a landscape device. A90 wrote transform=270 and
#    weston died with Invalid transform / Could not enable any output; the
#    accepted names are normal, rotate-90, rotate-180, rotate-270 and the four
#    flipped-* forms (weston-15.0.1 libweston/compositor.c transforms[]).
#    background-type=uniform was rejected the same way - the only values are
#    centered, scale, scale-crop, scale-fit, tile, so it is simply not set.
#  * put clients on the session. A91 used weston-tablet as the touch witness and
#    it drew nothing - a touchscreen sends pointer events, not tablet-tool events,
#    so that client never sees a finger. The witness is now the screenshot.
#  * keep a bounded window (A92: 25 minutes) and always put fbcon back after it,
#    so the panel is never permanently lost.
# Everything goes to the card. As a free side effect the patch phase copies the
# distro session units (armada-session-default, splash, gamescope) off the UFS
# root, which the truncated armada-root.img on this board cannot show us.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A92-PATCH"
CARD=/mnt/card
OUT=$CARD/y700-a92-patch.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac
echo "=== Y700-A92 session patch up=$(UP) ===" > "$OUT" 2>/dev/null
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
# A91: a weston session you can actually touch. Log lives in /tmp and is mirrored
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
T=/tmp/y700-a92-desktop.txt
mirror() {
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a92-desktop.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A92 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A92 $*" >> "$T" 2>/dev/null
	mirror
}
RUN=/run/y700-wayland
WINDOW=${Y700_WINDOW:-1500}
echo "===== Y700-A92 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} window=$WINDOW =====" >> "$T" 2>&1
{
	echo "-- dri --"; ls -l /dev/dri 2>&1
	for f in /sys/class/drm/card0*/modes; do echo "-- modes $f --"; cat "$f" 2>&1; done
	echo "-- backlight --"; for d in /sys/class/backlight/*; do echo "$d max=$(cat $d/max_brightness 2>&1) cur=$(cat $d/brightness 2>&1)"; done
	echo "-- input --"; ls -l /dev/input 2>&1
	echo "-- vtcon --"; cat /sys/class/vtconsole/vtcon*/name 2>&1
	echo "-- weston modules --"; ls /usr/lib64/libweston-15 2>&1
} >> "$T" 2>&1
mirror

FB=""
for b in /sys/class/vtconsole/vtcon1/bind; do
	[ -e "$b" ] || continue
	echo 0 > "$b" 2>/dev/null && FB="$b"
done
m "fbcon off via ${FB:-nothing}"

# The RTC reads out Oct 18 00:00 - no battery, no network. But the card was last
# written by a real PC: y700-task.sh carries a Shanghai wall-clock mtime, which
# this box (TZ=UTC at boot) reads 8 h ahead. Undo the offset, then push to RTC.
if [ -n "$CARD" ] && [ -e "$C/y700-task.sh" ]; then
	E=$(date -r "$C/y700-task.sh" +%s 2>/dev/null)
	m "card mtime epoch=$E"
	if [ -n "$E" ]; then
		date -u -s "@$((E - 28800))" >> "$T" 2>&1
		m "clock set rc=$? now_utc=$(date -u '+%F %T')"
		hwclock -u -w >> "$T" 2>&1
		m "hwclock rc=$?"
	fi
fi
for d in /sys/class/backlight/*; do
	[ -e "$d/brightness" ] || continue
	m "backlight ${d##*/} $(cat $d/brightness 2>/dev/null)/$(cat $d/max_brightness 2>/dev/null)"
	echo 1536 > "$d/brightness" 2>/dev/null && m "backlight raised to 1536"
done

mkdir -p $RUN
chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
export TZ=Asia/Shanghai

m "weston start window=${WINDOW}s"
/usr/bin/weston --backend=drm >> "$T" 2>&1 &
WP=$!
i=0
while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 25 ]; do sleep 1; i=$((i + 1)); done
m "wayland socket after ${i}s: $(ls $RUN 2>&1 | tr '\n' ' ')"
export WAYLAND_DISPLAY=wayland-1
if [ -S $RUN/wayland-1 ]; then
	SHOT=/tmp/y700shot
	mkdir -p $SHOT
	timeout 180 /usr/bin/weston-terminal >> "$T" 2>&1 &
	m "client launched weston-terminal(180s)"
	sleep 20
	# file_create_dated() puts the png in $XDG_PICTURES_DIR as
	# wayland-screenshot-<date>.png; cd there as well in case the env is ignored.
	(cd $SHOT && XDG_PICTURES_DIR=$SHOT timeout 30 /usr/bin/weston-screenshooter) >> "$T" 2>&1
	m "screenshooter rc=$?"
	SF=$(ls -t $SHOT/wayland-screenshot-*.png 2>/dev/null | head -1)
	if [ -n "$SF" ] && [ -n "$CARD" ]; then
		cp "$SF" "$C/y700-a92-shot.png" 2>/dev/null
		m "screenshot $(wc -c < "$SF" 2>/dev/null) bytes -> card rc=$?"
	else
		m "no screenshot (file=[$SF] card=${CARD:-none})"
	fi
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
U "desktop script v5 installed (screenshot + clock + backlight)"

cat > "$R/etc/xdg/weston/weston.ini" <<'INI'
# A90: the panel is a simple-framebuffer with one fixed mode, 1600x2560 mounted
# portrait. The tablet is held landscape, so rotate the logical output.
[core]
xkb-layout=us

[output]
name=Unknown-1
transform=rotate-270

[shell]
background-color=0x204080ff
panel-position=bottom
clock-format=minutes-24h

[libinput]
enable-tap=true
INI
U "weston.ini v4 installed (transform=rotate-270, panel bottom, tap)"

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
U "desktop unit v4 wanted by multi-user.target"

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