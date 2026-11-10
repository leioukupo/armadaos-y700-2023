#!/bin/sh
# A98: make the touchscreen follow the rotated panel, and never lose a log again.
#
# A97 turned the panel landscape (transform=rotate-270 read through --config=),
# and now dragging a window does nothing.  The A96 session log has the reason
# waiting in it: "input device event2 has no enabled output associated (none
# named), skipping calibration for now" - weston calibrates a touchscreen
# against a *named* output, and nothing ever named one.  With no calibration and
# a rotated output, the driver's panel-space coordinates land on the wrong part
# of the desktop, so a touch on a title bar grabs the wallpaper instead.
#
# A98 keeps boot_b on A96 and changes only the session script:
#  - [input-device] output=<connector> + calibration_matrix=<six>, read from
#    y700-touch.txt on the card, so the matrix is a text edit and not a reflash;
#  - a raw evdev capture (25 s, touch five points) next to the weston log, which
#    is the ground truth for the coordinates no matter what weston decides;
#  - every artifact written twice: to the card AND to /var/lib/y700 in the UFS
#    root.  A97's desktop log and weston-config probe never reached the card, so
#    the UFS copy is now the reliable readout.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A98-TOUCH"
CARD=/mnt/card
OUT=$CARD/y700-a98-patch.txt
CFG=$CARD/y700-a98-westoncfg.txt
INP=$CARD/y700-a98-input.txt
TOUCH=$CARD/y700-touch.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac

# the matrix weston gets is plain text on the card; rotate-270 wants
# x'=y, y'=1-x, i.e. 0 1 0 / -1 0 1.  Edit this file, not the script.
if [ ! -e "$TOUCH" ]; then
	{
		echo "associate=DSI-1"
		echo "matrix=0 1 0 -1 0 1"
		echo "capture=25"
	} > "$TOUCH"
fi
m "touch config: $(tr '\n' ';' < "$TOUCH" 2>/dev/null)"

echo "=== Y700-A98 patch up=$(UP) ===" > "$OUT" 2>/dev/null
U "rootdev=$RD"
[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
i=0
while [ ! -e /sys/block/sda/sda16 ] && [ "$i" -lt 90 ]; do
	sleep 5
	i=$((i + 5))
	m "ufs wait ${i}s"
done
U "ufs wait i=$i"
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; exit 1; }

MSG=$(mount -t ext4 -o rw /dev/sda16 /mnt/ufs 2>&1)
MR=$?
U "mount rw rc=$MR msg=$MSG"
[ "$MR" = "0" ] || { m "REFUSE cannot mount sda16 rw"; exit 1; }
R=/mnt/ufs
[ -x "$R/usr/bin/weston" ] || { m "REFUSE no weston in root"; umount /mnt/ufs; exit 1; }
mkdir -p "$R/usr/local/sbin" "$R/var/lib/y700" "$R/etc/systemd/system/multi-user.target.wants"

# ---------- what the distro itself configured, and what weston can parse ----------
cat "$R/etc/xdg/weston/weston.ini" > "$CFG" 2>/dev/null
CS=$(wc -c < "$CFG" 2>/dev/null)
cp "$CFG" "$R/var/lib/y700/westoncfg.txt" 2>/dev/null
U "distro ini bytes=$CS"
# busybox has no strings(1): turn the binary into lines and grep the config keys
tr -c '[:print:]' '\n' < "$R/usr/bin/weston" | sort -u > /tmp/ws.txt 2>/dev/null
{
	echo "-- input/libinput keys inside weston --"
	grep -x -E 'calibration_matrix|send-events|output|enable-tap|disable-cursor|cursor-theme|panel-position|background-color|painter-mode|shell-client-timeout|page-flip-time' /tmp/ws.txt 2>/dev/null
	echo "-- weston --show-config supported? --"
	grep -c 'show-config' /tmp/ws.txt 2>/dev/null
	echo "-- input devices and capabilities --"
	for e in /sys/class/input/event*; do
		[ -d "$e/device" ] || continue
		n=$(cat "$e/device/name" 2>/dev/null)
		echo "dev ${e##*/} name=$n"
		for c in ev key rel abs msc sw led; do
			v=$(cat "$e/device/capabilities/$c" 2>/dev/null)
			[ -n "$v" ] && echo "   cap $c=$v"
		done
	done
	echo "-- by-path --"
	ls -l /dev/input/by-path 2>&1
	echo "-- mt ranges from the driver --"
	for s in /sys/class/input/event*/device; do
		[ -d "$s" ] || continue
		echo "${s##*/}"
	done
} > "$INP" 2>&1
IS=$(wc -c < "$INP" 2>/dev/null)
cp "$INP" "$R/var/lib/y700/input.txt" 2>/dev/null
U "input/weston probe bytes=$IS"
ls -l "$CFG" "$INP" >> "$OUT" 2>/dev/null

cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A98: weston session with a named output for the touchscreen, a matrix from
# the card, and every artifact written to the UFS root as well as the card.
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
SPOOLD=/var/lib/y700
mkdir -p $SPOOLD
T=/tmp/y700-a98-desktop.txt
mirror() {
	cp "$T" "$SPOOLD/desktop.txt" 2>/dev/null
	sync
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a98-desktop.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A98 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A98 $*" >> "$T" 2>/dev/null
	mirror
}
survey() {
	{
		echo "-- dri --"; ls -l /dev/dri 2>&1
		for f in /sys/class/drm/card[0-9]*-*; do
			[ -d "$f" ] || continue
			echo "conn ${f##*/} status=$(cat $f/status 2>/dev/null)"
		done
		echo "-- fb --"; cat /proc/fb 2>&1
		echo "-- input --"; ls -l /dev/input/by-path 2>/dev/null
		for e in /sys/class/input/event*; do
			[ -d "$e/device" ] || continue
			echo "dev ${e##*/} name=$(cat $e/device/name 2>/dev/null) abs=$(cat $e/device/capabilities/abs 2>/dev/null)"
		done
	} >> "$T" 2>&1
}
RUN=/run/y700-wayland
WINDOW=${Y700_WINDOW:-900}
echo "===== Y700-A98 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} window=$WINDOW =====" >> "$T" 2>&1
survey
m "card mount=${CARD:-FAILED}"

FB=""
for b in /sys/class/vtconsole/vtcon1/bind; do
	[ -e "$b" ] || continue
	echo 0 > "$b" 2>/dev/null && FB="$b"
done
m "fbcon off via ${FB:-nothing}"

for d in /sys/class/backlight/*; do
	[ -e "$d/brightness" ] || continue
	echo 1536 > "$d/brightness" 2>/dev/null && m "backlight ${d##*/} raised $(cat $d/brightness 2>/dev/null)/$(cat $d/max_brightness 2>/dev/null)"
done

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
m "picked card=$KMS connector=${CONN:-none}"

# touch knobs come from the card so the matrix can be tuned without a patch
ASSOC="$CONN"
MATRIX=""
CAPT=25
if [ -n "$CARD" ] && [ -e "$C/y700-touch.txt" ]; then
	cp "$C/y700-touch.txt" $SPOOLD/touch.txt 2>/dev/null
	ASSOC=$(awk -F= '/^associate=/{print $2}' "$C/y700-touch.txt" 2>/dev/null)
	MATRIX=$(awk -F'matrix=' '/^matrix=/{print $2}' "$C/y700-touch.txt" 2>/dev/null)
	CAPT=$(awk -F= '/^capture=/{print $2}' "$C/y700-touch.txt" 2>/dev/null)
fi
[ -n "$ASSOC" ] || ASSOC="$CONN"
[ -n "$CAPT" ] || CAPT=25
m "touch associate=${ASSOC:-none} matrix=[${MATRIX:-none}] capture=${CAPT}s"

INI=$RUN/weston.ini
mkdir -p $RUN $RUN/weston
chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN
export XDG_CONFIG_HOME=$RUN
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
export TZ=Asia/Shanghai
if [ -f /etc/xdg/weston/weston.ini ]; then
	awk 'BEGIN{s=0} /^\[/{s=($0=="[output]")?1:0} !s' /etc/xdg/weston/weston.ini > "$INI" 2>/dev/null
else
	: > "$INI"
fi
{
	echo ""
	echo "[core]"
	echo "xkb-layout=us"
	echo ""
	echo "[output]"
	[ -n "$CONN" ] && echo "name=$CONN"
	echo "transform=rotate-270"
	echo ""
	echo "[input-device]"
	[ -n "$ASSOC" ] && echo "output=$ASSOC"
	[ -n "$MATRIX" ] && echo "calibration_matrix=$MATRIX"
	echo ""
	echo "[shell]"
	echo "background-color=0x204080ff"
	echo "panel-position=bottom"
	echo "clock-format=minutes-24h"
	echo ""
	echo "[libinput]"
	echo "enable-tap=true"
} >> "$INI"
cp "$INI" $RUN/weston.ini 2>/dev/null
cp "$INI" $RUN/weston/weston.ini 2>/dev/null
cp "$INI" $SPOOLD/weston.ini 2>/dev/null
m "ini written for connector=${CONN:-auto} transform=rotate-270 associate=${ASSOC:-none}"

try_weston() {
	DEVARG="$1"
	m "weston start window=${WINDOW}s args=[--config=$INI --backend=drm $DEVARG]"
	# shellcheck disable=SC2086
	/usr/bin/weston --config="$INI" --backend=drm $DEVARG >> "$T" 2>&1 &
	WP=$!
	i=0
	while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
	if [ -S $RUN/wayland-1 ]; then
		m "wayland socket after ${i}s ini-read=$(grep -m1 -o "Using config file '.*'" "$T" 2>/dev/null)"
		m "weston calibration lines: $(grep -iE 'calibration|associating input|Touchscreen' "$T" 2>/dev/null | tr '\n' ';' | cut -c1-300)"
		return 0
	fi
	m "no wayland socket after ${i}s, weston pid=$WP alive=$([ -d /proc/$WP ] && echo yes || echo no)"
	kill -TERM $WP 2>/dev/null
	sleep 3
	kill -KILL $WP 2>/dev/null
	wait $WP 2>/dev/null
	return 1
}

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

# ground truth for the coordinates: raw evdev for CAPT seconds while a finger
# walks the four corners and the centre.  evdev is multicast, so weston keeps
# working while this runs.
TP=""
for c in /dev/input/by-path/platform-990000.spi-cs-0-event /dev/input/event*; do
	[ -e "$c" ] || continue
	n=$(cat /sys/class/input/${c##*/}/device/name 2>/dev/null)
	case "$n" in
		*Touchscreen*) TP="$c"; break ;;
	esac
done
[ -n "$TP" ] || for e in /sys/class/input/event*; do
	[ -f "$e/device/name" ] || continue
	case "$(cat "$e/device/name" 2>/dev/null)" in
		*Touchscreen*) TP="/dev/input/${e##*/}"; break ;;
	esac
done
if [ -n "$TP" ]; then
	m "evdev capture start tp=$TP secs=$CAPT touch-corners-then-centre"
	timeout "$CAPT" cat "$TP" > $SPOOLD/ev.raw 2>/dev/null
	m "evdev capture done bytes=$(wc -c < $SPOOLD/ev.raw 2>/dev/null)"
	cp $SPOOLD/ev.raw "$C/y700-a98-ev.raw" 2>/dev/null && m "ev.raw copied to card"
	sync
else
	m "no Touchscreen node found, capture skipped"
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
{ echo "-- weston input/output lines --"; grep -iE "calibration|associating|Touchscreen|output DSI|transform|Output 'DSI" "$T" 2>/dev/null | tail -40; } >> "$T" 2>&1
survey
m "session over, fbcon back, PULL THE CARD NOW"
[ -n "$FB" ] && echo 1 > "$FB" 2>/dev/null
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v8 installed (named output + card matrix + evdev capture + UFS spool)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A98 weston session with a calibrated touchscreen
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
U "desktop unit v7 wanted by multi-user.target"

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
# END
