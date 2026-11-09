#!/bin/sh
# A76: the Novatek blob now lives inside the embedded initramfs, so the
# built-in driver should be able to request_firmware() during initcalls, i.e.
# before switch_root.  This round asks one question: does the touchscreen come
# up by itself at boot, with PIO, without any manual bind?  The first raw
# nt36523/firmware lines from the boot log go to the card so a failure says why
# (-ENOENT on the path vs a probe-order problem).
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A76'
CARD=/mnt/card
S=$CARD/y700-a76-step.txt
SUM=$CARD/y700-a76-summary.txt
CARDOK=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
E() { head -c 110 "$1" 2>/dev/null | tr '\n' ' '; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }

echo 7 4 1 7 > /proc/sys/kernel/printk 2>/dev/null
[ -d /mnt/card ] && mount -o remount,rw,sync /mnt/card 2>/dev/null
[ -e /mnt/card ] && CARDOK=1

mkdir -p /dev/shm 2>/dev/null
mount -t tmpfs -o size=300m tmpfs /dev/shm 2>/dev/null
SHM=/dev/shm
if ! touch "$SHM/.probe" 2>/dev/null; then
	mkdir -p /tmp/y700
	SHM=/tmp/y700
	touch "$SHM/.probe" 2>/dev/null
fi
rm -f "$SHM/.probe"

m "START up=$(UP) card=$CARDOK"
step state
PIO=/sys/module/spi_geni_qcom/parameters/force_pio
dmesg > "$SHM/d" 2>/dev/null
echo "=== Y700-A76 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
sum "force_pio=$(cat $PIO 2>/dev/null) root=$(mount 2>/dev/null | busybox grep ' / ' | busybox cut -d' ' -f1-3)"
sum "spi=$(LS /sys/bus/spi/devices) input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
sum "boot-nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d 2>/dev/null) nvt-end=$(grep -c 'NVT-FW end' $SHM/d 2>/dev/null) validated=$(grep -c 'validated firmware' $SHM/d 2>/dev/null) crcsnap=$(grep -c 'CRC snapshot' $SHM/d 2>/dev/null)"
sum "boot-genimode=$(grep -m1 'Y700-GENI xfer' $SHM/d 2>/dev/null)"
grep -iE 'nt36523|firmware' "$SHM/d" 2>/dev/null | head -6 > "$SHM/b"
i=1
while [ $i -le 6 ]; do
	line=$(sed -n "${i}p" "$SHM/b" 2>/dev/null)
	[ -n "$line" ] || break
	sum "bootlog$i=$(E "$line")"
	i=$((i + 1))
done
grep -iE 'NVT-FW|validated firmware|CRC snapshot' "$SHM/d" 2>/dev/null | tail -4 > "$SHM/key"
m "KEY $(E "$SHM/key")"
F

# is the touchscreen there already, without any help from this script?
TOUCH=""
EV=""
for i in /sys/class/input/input*; do
	[ -e "$i/name" ] || continue
	nm=$(cat "$i/name" 2>/dev/null)
	case "$nm" in
	*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) TOUCH=${i##*/}; EV=e${i##*input} ;;
	esac
done
[ -n "$TOUCH" ] 2>/dev/null || {
	for i in /sys/class/input/event*; do
		[ -e "$i/device/name" ] || continue
		nm=$(cat "$i/device/name" 2>/dev/null)
		case "$nm" in
		*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) TOUCH=${i##*/}; EV=${i##*/} ;;
		esac
	done
}
[ -n "$EV" ] 2>/dev/null && [ "${EV#event}" != "$EV" ] && EV=${EV#event}
sum "touch-input=${TOUCH:-NONE} event=${EV:-NONE}"
if [ -n "$TOUCH" ] 2>/dev/null; then
	m "A76-MARK-1 BOOT-TOUCH-AUTO input=$TOUCH up=$(UP)"
	sum "boot-touch=auto"
else
	m "A76-MARK-1 NO-BOOT-TOUCH re-bind now up=$(UP)"
	sum "boot-touch=manual"
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/unbind 2>/dev/null
	done
	sleep 2
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/bind 2>/dev/null
	done
	sleep 6
	dmesg > "$SHM/d2" 2>/dev/null
	grep -iE 'NVT-FW|validated firmware|CRC snapshot' "$SHM/d2" 2>/dev/null | tail -3 > "$SHM/k2"
	m "KEY2 $(E "$SHM/k2")"
	sum "rebind-nvt-end=$(grep -c 'NVT-FW end' $SHM/d2 2>/dev/null)"
	for i in /sys/class/input/event*; do
		[ -e "$i/device/name" ] || continue
		nm=$(cat "$i/device/name" 2>/dev/null)
		case "$nm" in
		*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) EV=${i##*/} ;;
		esac
	done
fi
step touch
if [ -n "$EV" ] 2>/dev/null; then
	( timeout 28 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 13 ]; do
		m "TOUCHNOW $i swipe-with-one-finger"
		i=$((i + 1))
		sleep 2
	done
	wait $CAT 2>/dev/null
	sz=$(wc -c < "$SHM/events.bin" 2>/dev/null)
	sz=${sz:-0}
	m "A76-MARK-2 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
else
	m "A76-MARK-2 no-event-device"
	sum "events-bytes=NONE"
fi
F
rm -f "$SHM/d" "$SHM/d2" "$SHM/b" 2>/dev/null
sleep 2
m "A76-MARK-3 read-the-card-when-this-stops up=$(UP)"
step exit