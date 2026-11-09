#!/bin/sh
# A75: is the fix allowed to be permanent? force_pio is now the kernel default,
# and A74 left novatek/lenovo-tb320fc.bin in the UFS rootfs, so this round asks
# whether the touchscreen comes up by itself during boot - no stage walk, no
# manual bind, no DMA control test.  It also says out loud, on the panel, what
# the next card-less boot would do, because the y700 ramlog replays the previous
# boot's log into this one.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A75'
CARD=/mnt/card
S=$CARD/y700-a75-step.txt
SUM=$CARD/y700-a75-summary.txt
CARDOK=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
E() { head -c 240 "$1" 2>/dev/null | tr '\n' ' '; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }

echo 7 4 1 7 > /proc/sys/kernel/printk 2>/dev/null
[ -d /mnt/card ] && mount -o remount,rw,sync /mnt/card 2>/dev/null
[ -e /mnt/card ] && CARDOK=1

mkdir -p /dev/shm 2>/dev/null
mount -t tmpfs -o size=900m tmpfs /dev/shm 2>/dev/null
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
echo "=== Y700-A75 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
sum "force_pio-default=$(cat $PIO 2>/dev/null) (expect Y: PIO is the built-in default now)"
sum "root=$(mount 2>/dev/null | busybox grep ' / ' | busybox tr '\n' '|')"
sum "fw-on-rootfs=$(ls -l /lib/firmware/novatek 2>/dev/null | busybox tr '\n' '|')"
sum "spi-devices=$(LS /sys/bus/spi/devices) driver-dir=$(LS /sys/bus/spi/drivers)"
sum "input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
sum "boot-nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d 2>/dev/null) boot-nvt-end=$(grep -c 'NVT-FW end' $SHM/d 2>/dev/null)"
sum "boot-validated=$(grep -c 'validated firmware' $SHM/d 2>/dev/null) boot-crcsnap=$(grep -c 'CRC snapshot' $SHM/d 2>/dev/null)"
sum "boot-genimode=$(grep -m1 'Y700-GENI xfer' $SHM/d 2>/dev/null)"
sum "boot-probe-fail=$(grep -icE 'nt36523.*(fail|error|defer|no such file)' $SHM/d 2>/dev/null)"
grep -iE 'NVT-FW|validated firmware|CRC snapshot|Y700-GENI xfer|nt36523' "$SHM/d" 2>/dev/null | tail -5 > "$SHM/key"
m "KEY $(E "$SHM/key")"
F

# which event device is the touchscreen, and did it appear by itself?
TOUCH=""
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
cat /proc/bus/input/devices 2>/dev/null | grep -A4 -iE 'nt36523|novatek|touch' | head -12 > "$SHM/in"
sum "input-dev=$(E "$SHM/in")"
if [ -n "$TOUCH" ] 2>/dev/null; then
	m "A75-MARK-1 TOUCH-UP-BY-ITSELF input=$TOUCH up=$(UP)"
	sum "boot-touch=auto"
else
	m "A75-MARK-1 NO-BOOT-TOUCH, re-binding now up=$(UP)"
	sum "boot-touch=manual"
	echo 1 > "$PIO" 2>/dev/null
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/unbind 2>/dev/null
	done
	sleep 2
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/bind 2>/dev/null
		m "BOUND ${d##*/} up=$(UP)"
	done
	sleep 6
	dmesg > "$SHM/d2" 2>/dev/null
	grep -iE 'NVT-FW|validated firmware|CRC snapshot|Y700-GENI xfer' "$SHM/d2" 2>/dev/null | tail -5 > "$SHM/key"
	m "KEY2 $(E "$SHM/key")"
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
	( timeout 30 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 14 ]; do
		m "TOUCHNOW $i swipe-with-one-finger"
		i=$((i + 1))
		sleep 2
	done
	wait $CAT 2>/dev/null
	sz=$(wc -c < "$SHM/events.bin" 2>/dev/null)
	sz=${sz:-0}
	m "A75-MARK-2 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
else
	m "A75-MARK-2 no-event-device"
	sum "events-bytes=NONE"
fi
F

step persist
FW=/lib/firmware/novatek/lenovo-tb320fc.bin
if [ -s "$FW" ]; then
	sum "fw-persist=present bytes=$(wc -c < "$FW" 2>/dev/null)"
else
	mkdir -p /lib/firmware/novatek 2>/dev/null
	for src in /mnt/card/y700-a71-fw/novatek_ts_fw.bin /mnt/card/y700-a73-ts_fw.bin; do
		[ -s "$src" ] && cp -f "$src" "$FW" 2>/dev/null && break
	done
	if [ ! -s "$FW" ]; then
		cp -f /mnt/card/y700-fwfetch "$SHM/fwf" 2>/dev/null
		chmod +x "$SHM/fwf" 2>/dev/null
		timeout 130 "$SHM/fwf" /dev/sda10 0 "$SHM/fw" > "$SHM/fwout" 2>&1
		cp -f "$SHM/fw/novatek_ts_fw.bin" "$FW" 2>/dev/null
		sum "fw-persist=fetched rc=$?"
	fi
	sum "fw-persist-after=$(ls -l /lib/firmware/novatek 2>/dev/null | busybox tr '\n' '|')"
fi
F
m "A75-MARK-3 firmware-in-rootfs-check-done up=$(UP)"
sleep 2
m "A75-MARK-4 read-the-card-when-this-stops up=$(UP)"
step exit