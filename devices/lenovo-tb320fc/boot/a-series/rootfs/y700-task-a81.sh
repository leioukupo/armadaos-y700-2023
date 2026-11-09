#!/bin/sh
# A81: fbcon is built in and y700fb hands the panel over by default, so the
# console should be the display now.  The card cannot see the glass, so it
# writes the state (vtcon, consoles, fb devices) and then does the one thing
# that settles it: it prints a line straight onto /dev/tty0.  If fbcon is bound,
# that line appears on the panel a couple of seconds after boot.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A81'
CARD=/mnt/card
S=$CARD/y700-a81-step.txt
SUM=$CARD/y700-a81-summary.txt
CARDOK=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }

echo 7 4 1 7 > /proc/sys/kernel/printk 2>/dev/null
[ -d /mnt/card ] && mount -o remount,rw,sync /mnt/card 2>/dev/null
[ -e /mnt/card ] && CARDOK=1

mkdir -p /dev/shm 2>/dev/null
mount -t tmpfs -o size=200m tmpfs /dev/shm 2>/dev/null
SHM=/dev/shm
if ! touch "$SHM/.probe" 2>/dev/null; then
	mkdir -p /tmp/y700
	SHM=/tmp/y700
	touch "$SHM/.probe" 2>/dev/null
fi
rm -f "$SHM/.probe"

m "START up=$(UP) card=$CARDOK"
step state
dmesg > "$SHM/d" 2>/dev/null
echo "=== Y700-A81 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
F
sum "fb=$(LS /sys/class/graphics) vtcon=$(LS /sys/class/vtconsole) input=$(LS /sys/class/input)"
sum "vtcon-names=$(cat /sys/class/vtconsole/vtcon*/name 2>/dev/null | busybox tr '\n' '|') consoles=$(cat /proc/consoles 2>/dev/null | busybox tr '\n' '|')"
sum "fb0-mode=$(cat /sys/class/graphics/fb0/modes 2>/dev/null) fb0-vmode=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
grep -aiE 'Y700-FB|fbcon|fb0|console' "$SHM/d" 2>/dev/null | tail -n 8 | busybox cut -c1-140 > "$SHM/g"
sum "-- fb/console lines --"
cat "$SHM/g" >> "$SUM" 2>/dev/null
F

m "A81-MARK-1 tty0-test-line-in-3s up=$(UP)"
sleep 3
printf '\nY700-A81 FBCON-OK if you can read this on the panel\n' > /dev/tty0 2>/dev/null
sum "tty0-write-rc=$?"
step tty0
sleep 3

EV=""
for i in /sys/class/input/event*; do
	[ -e "$i/device/name" ] || continue
	nm=$(cat "$i/device/name" 2>/dev/null)
	case "$nm" in
	*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) EV=${i##*/} ;;
	esac
done
sum "touch-event=${EV:-NONE} nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d) snapshot=$(grep -c 'CRC snapshot' $SHM/d) timedout=$(grep -c 'SPI transfer timed out' $SHM/d)"
if [ -n "$EV" ] 2>/dev/null; then
	m "A81-MARK-2 TOUCH-STILL-OK event=$EV up=$(UP)"
	( timeout 20 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 9 ]; do
		m "TOUCHNOW $i swipe-with-one-finger"
		i=$((i + 1))
		sleep 2
	done
	wait $CAT 2>/dev/null
	sz=$(wc -c < "$SHM/events.bin" 2>/dev/null)
	sz=${sz:-0}
	m "A81-MARK-3 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
else
	m "A81-MARK-2 touch-missing"
	sum "events-bytes=NONE"
fi
F
m "A81-MARK-4 read-the-card-when-this-stops up=$(UP)"
step exit