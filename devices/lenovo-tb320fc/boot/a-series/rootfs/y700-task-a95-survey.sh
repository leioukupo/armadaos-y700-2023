#!/bin/sh
# A94: hand the real display chain over to Linux, and make the desktop follow
# whichever DRM card actually owns the panel.
#
# The boot image for this round is A88 plus one DTB change (a94-build.sh):
# mdss / dpu / dsi0 / dsi1 / both 7nm DSI PHYs / dispcc are no longer
# status="disabled", so drivers/gpu/drm/msm + panel-novatek-nt36523 +
# ktz8866 can bind for real, while apps_smmu (iommu@15000000) stays pinned off
# and every iommus property stays stripped - ABL's bypassed streams keep the
# DPU's DMA working on physical addresses, which is what A47/A54 died without.
# CONFIG_DRM_SIMPLEDRM stays on, so if the DPU never binds the panel still
# behaves exactly like A88 instead of going dark.
#
# This task does two things:
#  1. round 1 (card root): survey what the display chain did while the card root
#     was booting - card list, connector status/modes, backlight, fb, deferred
#     devices, dmesg lines.  That answer is the whole point of the round, and it
#     is on the card before weston can turn the panel off.
#  2. patch the UFS root so the session script picks the DPU card by looking at
#     which card's device is a display-controller (simpledrm's is a framebuffer
#     platform device), writes weston.ini with the connector name the kernel
#     actually exported, and passes --device= accordingly.  The A92 clock bug
#     (an extra -8 h on top of an already-UTC epoch) and the dead
#     weston-screenshooter (weston 15.0.1 never authorises capture) are gone.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A95-SURVEY"
CARD=/mnt/card
OUT=$CARD/y700-a95-patch.txt
R1=$CARD/y700-a95-survey.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac

# ---------- round 1: the display survey, before anything can grab the panel ----------
{
	echo "=== Y700-A95 display survey up=$(UP) ==="
	echo "-- cmdline --"; cat /proc/cmdline 2>&1
	echo "-- dri --"; ls -l /dev/dri 2>&1
	echo "-- drm class --"; ls -l /sys/class/drm 2>&1
	echo "-- cards and their devices --"
	for d in /sys/class/drm/card[0-9]*; do
		[ -d "$d" ] || continue
		echo "$d device=$(readlink -f "$d/device" 2>/dev/null)"
	done
	echo "-- connectors --"
	for f in /sys/class/drm/card[0-9]*-*; do
		[ -d "$f" ] || continue
		echo "== ${f##*/} status=$(cat $f/status 2>/dev/null) edid_bytes=$(wc -c < $f/edid 2>/dev/null)"
		cat "$f/modes" 2>/dev/null
	done
	echo "-- backlight --"
	for d in /sys/class/backlight/*; do
		[ -e "$d" ] || continue
		echo "$d cur=$(cat $d/brightness 2>&1) max=$(cat $d/max_brightness 2>&1)"
	done
	echo "-- fb --"; cat /proc/fb 2>&1
	echo "-- consoles --"; cat /proc/consoles 2>&1
	echo "-- vtcon --"; for v in /sys/class/vtconsole/vtcon*; do echo "$v name=$(cat $v/name 2>/dev/null) bind=$(cat $v/bind 2>/dev/null)"; done
	echo "-- drivers bound --"
	for p in msm-mdss msm_dpu msm_dsi panel-novatek-nt36523 panel-y700-stub novatek-nt36523n-spi ktz8866 simpledrm y700-fb; do
		d=/sys/bus/platform/drivers/$p
		[ -d "$d" ] || continue
		echo "$p: $(ls $d 2>/dev/null | tr '\n' ' ')"
	done
	echo "-- dmesg display chain --"
	dmesg 2>/dev/null | grep -iE "mdss|dpu|dsi|panel|dispcc|component|drm|defer|nt36523|ktz8866|backlight|simplefb|simpledrm|framebuffer|aperture|sysfb|y700-fb|error|fail" | tail -240
	echo "-- deferred devices --"
	mkdir -p /tmp/dbg 2>/dev/null
	mount -t debugfs none /tmp/dbg 2>/dev/null
	cat /tmp/dbg/devices_deferred 2>&1 | head -40
	echo "-- dri state --"
	cat /tmp/dbg/dri/*/state 2>&1 | head -80
	echo "-- dmesg tail --"; dmesg 2>/dev/null | tail -40
} > "$R1" 2>&1
sync
m "round1 survey written $(wc -c < "$R1" 2>/dev/null) bytes"

# ---------- the card/panel answer is a time series, not a snapshot ----------
sample() {
	{
		echo "### sample up=$(UP) reason=$1 ###"
		echo "-- dri --"; ls -l /dev/dri 2>&1
		echo "-- drm class --"; ls /sys/class/drm 2>&1
		echo "-- fb --"; cat /proc/fb 2>&1
		echo "-- consoles --"; cat /proc/consoles 2>&1
		echo "-- drivers bound --"
		for p in msm-mdss msm_dpu msm_dsi panel-novatek-nt36523 panel-y700-stub novatek-nt36523n-spi ktz8866 simpledrm y700-fb; do
			d=/sys/bus/platform/drivers/$p
			[ -d "$d" ] || continue
			echo "$p: $(ls $d 2>/dev/null | tr '\n' ' ')"
		done
		echo "-- mdss master --"; ls -l /sys/devices/platform/soc@0/ae00000.display-subsystem 2>&1
	} >> "$R1" 2>&1
	sync
	m "sample up=$(UP) dri=$(ls /dev/dri 2>/dev/null | tr '\n' ' ') fb=$(cut -d\  -f1 /proc/fb 2>/dev/null | tr '\n' ' ')"
}

# UFS now enumerates after the display chain (A94 saw no sda16 at up=9 and
# refused to patch).  Wait for it instead of trusting the snapshot.
i=0
while [ ! -e /sys/block/sda/sda16 ] && [ "$i" -lt 150 ]; do
	sleep 5
	i=$((i + 5))
	[ $((i % 15)) = 0 ] && sample "waiting-for-ufs-${i}s"
done
U "ufs wait i=$i present=$([ -e /sys/block/sda/sda16 ] && echo yes || echo no) blocks=$(ls /sys/block 2>/dev/null | tr '\n' ' ')"
m "ufs wait done i=${i}s"
sample "after-ufs-wait"

# ---------- patch the UFS root ----------
echo "=== Y700-A95 session patch up=$(UP) ===" > "$OUT" 2>/dev/null
U "rootdev=$RD"
[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; exit 1; }

MSG=$(mount -t ext4 -o rw /dev/sda16 /mnt/ufs 2>&1)
MR=$?
U "mount rw rc=$MR msg=$MSG"
[ "$MR" = "0" ] || { m "REFUSE cannot mount sda16 rw"; exit 1; }
R=/mnt/ufs
[ -x "$R/usr/bin/weston" ] || { m "REFUSE no weston in root"; umount /mnt/ufs; exit 1; }
mkdir -p "$R/usr/local/sbin" "$R/etc/systemd/system/multi-user.target.wants"

cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A94: a weston session on whichever DRM card really owns the panel.  The log
# lives in /tmp and is mirrored to the card on our own mount point, so the A87b
# diag unit cannot pull it away.
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
T=/tmp/y700-a95-desktop.txt
mirror() {
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a95-desktop.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A95 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A95 $*" >> "$T" 2>/dev/null
	mirror
}
survey() {
	{
		echo "-- dri --"; ls -l /dev/dri 2>&1
		for d in /sys/class/drm/card[0-9]*; do
			[ -d "$d" ] || continue
			echo "card ${d##*/} device=$(readlink -f "$d/device" 2>/dev/null)"
		done
		for f in /sys/class/drm/card[0-9]*-*; do
			[ -d "$f" ] || continue
			echo "conn ${f##*/} status=$(cat $f/status 2>/dev/null)"
			cat "$f/modes" 2>/dev/null
		done
		echo "-- fb --"; cat /proc/fb 2>&1
		echo "-- backlight --"; for d in /sys/class/backlight/*; do [ -e "$d" ] && echo "$d cur=$(cat $d/brightness 2>&1) max=$(cat $d/max_brightness 2>&1)"; done
		echo "-- input --"; ls -l /dev/input/by-path 2>/dev/null; ls /dev/input 2>&1
	} >> "$T" 2>&1
}
RUN=/run/y700-wayland
XDGCFG=$RUN/xdg
WINDOW=${Y700_WINDOW:-1200}
echo "===== Y700-A95 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} window=$WINDOW =====" >> "$T" 2>&1
survey
mirror

FB=""
for b in /sys/class/vtconsole/vtcon1/bind; do
	[ -e "$b" ] || continue
	echo 0 > "$b" 2>/dev/null && FB="$b"
done
m "fbcon off via ${FB:-nothing}"

# The RTC is dead (no battery, no /dev/rtc).  The card was last written by a
# real PC, so y700-task.sh's mtime is a usable wall time.  The box boots in UTC,
# so date -r already yields the right epoch - A92 subtracted 8 h on top of that
# and the shell clock ended up 8 h slow.  No hwclock either: nothing to write.
if [ -n "$CARD" ] && [ -e "$C/y700-task.sh" ]; then
	E=$(date -r "$C/y700-task.sh" +%s 2>/dev/null)
	if [ -n "$E" ]; then
		date -u -s "@$E" >> "$T" 2>&1
		m "clock set from card mtime now_utc=$(date -u '+%F %T')"
	fi
fi
for d in /sys/class/backlight/*; do
	[ -e "$d/brightness" ] || continue
	echo 1536 > "$d/brightness" 2>/dev/null && m "backlight ${d##*/} raised $(cat $d/brightness 2>/dev/null)/$(cat $d/max_brightness 2>/dev/null)"
done

# Which card owns the glass?  The DPU card's device is a display-controller
# platform device; simpledrm's is the framebuffer one.  Prefer the real KMS.
KMS=""
CONN=""
for d in /sys/class/drm/card[0-9]*; do
	[ -d "$d" ] || continue
	case "$(readlink -f "$d/device" 2>/dev/null)" in
		*display-controller*) KMS=${d##*/}; break ;;
	esac
done
[ -n "$KMS" ] || for d in /sys/class/drm/card[0-9]*; do
	[ -d "$d" ] || continue
	KMS=${d##*/}
	break
done
for f in /sys/class/drm/$KMS-*; do
	[ -d "$f" ] || continue
	if [ "$(cat "$f/status" 2>/dev/null)" = "connected" ]; then
		CONN=${f##*/$KMS-}
		break
	fi
done
[ -n "$CONN" ] || for f in /sys/class/drm/$KMS-*; do
	[ -d "$f" ] || continue
	CONN=${f##*/$KMS-}
	break
done
m "picked card=$KMS connector=${CONN:-none} devices=$(ls /dev/dri/card* 2>/dev/null | tr '\n' ' ')"

mkdir -p $RUN $XDGCFG/weston
chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN
export XDG_CONFIG_HOME=$XDGCFG
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
export TZ=Asia/Shanghai
{
	echo "[core]"
	echo "xkb-layout=us"
	echo ""
	echo "[output]"
	[ -n "$CONN" ] && echo "name=$CONN"
	echo "transform=rotate-270"
	echo ""
	echo "[shell]"
	echo "background-color=0x204080ff"
	echo "panel-position=bottom"
	echo "clock-format=minutes-24h"
	echo ""
	echo "[libinput]"
	echo "enable-tap=true"
} > $XDGCFG/weston/weston.ini
m "weston.ini written for connector=${CONN:-auto}"

try_weston() {
	DEVARG="$1"
	m "weston start window=${WINDOW}s args=[${DEVARG}]"
	# shellcheck disable=SC2086
	/usr/bin/weston --backend=drm $DEVARG >> "$T" 2>&1 &
	WP=$!
	i=0
	while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
	if [ -S $RUN/wayland-1 ]; then
		m "wayland socket after ${i}s: $(ls $RUN 2>&1 | tr '\n' ' ')"
		return 0
	fi
	m "no wayland socket after ${i}s, weston pid=$WP alive=$([ -d /proc/$WP ] && echo yes || echo no)"
	kill -TERM $WP 2>/dev/null
	sleep 3
	kill -KILL $WP 2>/dev/null
	wait $WP 2>/dev/null
	return 1
}

# weston 15 renamed the drm backend option to --drm-device=<cardN>, a udev sysname
# and not a path; the old --device=/dev/dri/cardN form would abort startup.
if ! try_weston "--drm-device=$KMS"; then
	if [ "$KMS" != "card0" ]; then
		rm -f $RUN/wayland-* 2>/dev/null
		try_weston "--drm-device=card0" || try_weston ""
	else
		try_weston ""
	fi
fi
export WAYLAND_DISPLAY=wayland-1
if [ -S $RUN/wayland-1 ]; then
	timeout $((WINDOW - 30)) /usr/bin/weston-terminal >> "$T" 2>&1 &
	m "client launched weston-terminal"
else
	m "no wayland socket, clients skipped"
fi

if [ -n "$WP" ] && [ -d /proc/$WP ]; then
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
fi
mkdir -p /tmp/dbg 2>/dev/null
mount -t debugfs none /tmp/dbg 2>/dev/null
{ echo "-- dri state after --"; cat /tmp/dbg/dri/*/state 2>&1 | head -120; } >> "$T" 2>&1
survey
m "session over, fbcon back, PULL THE CARD NOW"
[ -n "$FB" ] && echo 1 > "$FB" 2>/dev/null
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v6 installed (card pick + generated ini + clock fix)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A94 weston session on the real KMS card
After=seatd.service systemd-user-sessions.service

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
U "desktop unit v5 wanted by multi-user.target (no card0 device pin)"

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