#!/bin/sh
# A97: make weston actually read our ini, so the panel turns landscape.
#
# A96 got a real KMS (card1 / DSI-1 / 1600x2560@120) and a weston desktop on the
# UFS root, but the desktop stayed portrait with the taskbar on the short edge.
# The session log says why: "Using config file '/etc/xdg/weston/weston.ini'" -
# weston never saw the ini we generated.  It looks for $XDG_CONFIG_HOME/weston.ini,
# while A96 wrote $XDG_CONFIG_HOME/weston/weston.ini, so weston fell back to the
# distro file, whose [output] section names simpledrm's Unknown-1 and matches
# nothing now that the connector is DSI-1.
#
# A97 changes nothing in the boot image (boot_b stays A96) and only rewrites the
# session script: build one ini, write it where weston really looks, and hand it
# over explicitly with --config=.  The distro ini is kept as the base with its
# [output] blocks dropped, so an ArmadaOS setting we do not know about survives
# while our DSI-1 rotation wins.  Round 2 copies weston's own "Using config
# file" line into the card log, so the card proves which file was used.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A97-ROTATE"
CARD=/mnt/card
OUT=$CARD/y700-a97-patch.txt
R1=$CARD/y700-a97-survey.txt
R0=$CARD/y700-a97-dmesg.txt
CFG=$CARD/y700-a97-westoncfg.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac

# ---------- round 1: what the display chain did, plus the distro ini ----------
{
	echo "=== Y700-A97 survey up=$(UP) ==="
	echo "-- cmdline --"; cat /proc/cmdline 2>&1
	echo "-- cards and their devices --"
	for d in /sys/class/drm/card[0-9]*; do
		[ -d "$d" ] || continue
		echo "$d device=$(readlink -f "$d/device" 2>/dev/null)"
	done
	echo "-- connectors --"
	for f in /sys/class/drm/card[0-9]*-*; do
		[ -d "$f" ] || continue
		echo "${f##*/} status=$(cat $f/status 2>/dev/null)"
		cat $f/modes 2>/dev/null
	done
	echo "-- backlight --"
	for d in /sys/class/backlight/*; do
		[ -e "$d" ] || continue
		echo "$d cur=$(cat $d/brightness 2>&1) max=$(cat $d/max_brightness 2>&1)"
	done
	echo "-- fb --"; cat /proc/fb 2>&1
	echo "-- input --"; ls /dev/input 2>&1
	echo "-- iommu --"; ls /sys/class/iommu 2>&1; echo "groups=$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)"
	echo "-- blocks --"; ls /sys/block 2>&1
} > "$R1" 2>&1
dmesg > "$R0" 2>&1
sync
m "survey=$(wc -c < "$R1" 2>/dev/null) dmesg=$(wc -c < "$R0" 2>/dev/null)"

i=0
while [ "$i" -lt 6 ]; do
	m "A97-MARK-$i rotation-next"
	i=$((i + 1))
done

# UFS enumerates after the display chain now, so wait instead of trusting the
# snapshot taken a second after boot.
mkdir -p /tmp/dbg 2>/dev/null
mount -t debugfs none /tmp/dbg 2>/dev/null
i=0
while [ ! -e /sys/block/sda/sda16 ] && [ "$i" -lt 150 ]; do
	sleep 5
	i=$((i + 5))
	m "ufs wait ${i}s blocks=$(ls /sys/block 2>/dev/null | tr '\n' ' ')"
done
U "ufs wait i=$i present=$([ -e /sys/block/sda/sda16 ] && echo yes || echo no)"
m "ufs wait done i=${i}s"

# ---------- patch the UFS root ----------
echo "=== Y700-A97 session patch up=$(UP) ===" > "$OUT" 2>/dev/null
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

# what the distro itself configured - copied to the card so the next round can
# reuse it, and used as the base of the ini we generate
{
	echo "== ls /etc/xdg/weston =="
	ls -l $R/etc/xdg/weston 2>&1
	echo "== /etc/xdg/weston/weston.ini =="
	cat $R/etc/xdg/weston/weston.ini 2>&1
	echo "== weston accepts --config? =="
	grep -a -c -- '--config' $R/usr/bin/weston 2>&1
	echo "== weston version =="
	ls -l $R/usr/bin/weston 2>&1
	strings $R/usr/bin/weston 2>/dev/null | grep -m2 -E '^1[0-9]\.[0-9]+\.[0-9]+$'
} > "$CFG" 2>&1
sync
U "distro weston config copied to card ($(wc -c < "$CFG" 2>/dev/null) bytes)"

cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A97: weston session with an ini it provably reads.  Log in /tmp, mirrored to
# the card on our own mount point so the A87b diag unit cannot pull it away.
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
T=/tmp/y700-a97-desktop.txt
mirror() {
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a97-desktop.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A97 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A97 $*" >> "$T" 2>/dev/null
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
			cat $f/modes 2>/dev/null
		done
		echo "-- fb --"; cat /proc/fb 2>&1
		echo "-- backlight --"; for d in /sys/class/backlight/*; do [ -e "$d" ] && echo "$d cur=$(cat $d/brightness 2>/dev/null) max=$(cat $d/max_brightness 2>/dev/null)"; done
		echo "-- input --"; ls -l /dev/input/by-path 2>/dev/null; ls /dev/input 2>&1
	} >> "$T" 2>&1
}
RUN=/run/y700-wayland
WINDOW=${Y700_WINDOW:-900}
echo "===== Y700-A97 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} window=$WINDOW =====" >> "$T" 2>&1
survey

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

# Which card owns the glass?  The DPU card's device is a display-controller
# platform device; simpledrm's is the framebuffer one.
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

INI=$RUN/weston.ini
mkdir -p $RUN $RUN/weston
chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN
export XDG_CONFIG_HOME=$RUN
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
export TZ=Asia/Shanghai

# base = whatever ArmadaOS shipped, minus its [output] sections (they name the
# connector the distro expected, not the one the kernel exported for us).
if [ -f /etc/xdg/weston/weston.ini ]; then
	awk 'BEGIN{s=0} /^\[/{s=($0=="[output]")?1:0} !s' /etc/xdg/weston/weston.ini > "$INI" 2>/dev/null
	m "ini base from /etc/xdg/weston/weston.ini lines=$(wc -l < "$INI" 2>/dev/null)"
else
	: > "$INI"
	m "ini base empty, distro has no /etc/xdg/weston/weston.ini"
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
m "ini written $INI for connector=${CONN:-auto} transform=rotate-270"

try_weston() {
	DEVARG="$1"
	m "weston start window=${WINDOW}s args=[--config=$INI --backend=drm $DEVARG]"
	# shellcheck disable=SC2086
	/usr/bin/weston --config="$INI" --backend=drm $DEVARG >> "$T" 2>&1 &
	WP=$!
	i=0
	while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
	if [ -S $RUN/wayland-1 ]; then
		m "wayland socket after ${i}s: $(ls $RUN 2>/dev/null | tr '\n' ' ')"
		m "weston read ini=$(grep -m1 -o "Using config file '.*'" "$T" 2>/dev/null)"
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
{ echo "-- weston output lines --"; grep -iE "output|transform|mode|seat" "$T" 2>/dev/null | tail -40; } >> "$T" 2>&1
survey
m "session over, fbcon back, PULL THE CARD NOW"
[ -n "$FB" ] && echo 1 > "$FB" 2>/dev/null
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v7 installed (explicit --config, ini base from distro)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A97 weston session with an ini it reads
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
U "desktop unit v6 wanted by multi-user.target"

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
