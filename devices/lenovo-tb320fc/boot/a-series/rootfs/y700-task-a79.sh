#!/bin/sh
# A79: A78 said exactly where the boot-time download dies - the host, not the IC:
#   NVT-FW part0 written (2 chunks, 98112 bytes)
#   Y700-GENI xfer 52073 B mode=1 (PIO)
#   SPI transfer timed out  ->  NVT-FW end error=-110
#   error -ETIMEDOUT: firmware SRAM transfer failed
# spi/core.c:spi_transfer_wait() budgets 2*(8000*len/speed_hz)+200 ms, i.e. it
# trusts spi-max-frequency=9600000, but PIO through the 64-byte SE FIFO only
# moves ~250 KB/s, so 52073 B was allowed 286 ms and needed more.  The vendor
# 63 KiB chunk is therefore a coin toss.  A79 tests the fix without a rebuild:
# nvt_fw_chunk is a 0644 knob, so cut every SPI write to 16 KiB (budget 227 ms,
# actual ~65 ms) and re-bind.  If the two CRC snapshots and the input device
# then show up, the next build makes 16 KiB the built-in default.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A79'
CARD=/mnt/card
S=$CARD/y700-a79-step.txt
SUM=$CARD/y700-a79-summary.txt
CARDOK=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }
lines() { grep -aiE 'nt36523|NVT-|geni_spi 990000|CRC snapshot|timed out|firmware .* failed' "$1" 2>/dev/null | tail -n $2 | busybox cut -c1-150; }

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
CHUNK=/sys/module/novatek_nt36523n_spi/parameters/nvt_fw_chunk
dmesg > "$SHM/d" 2>/dev/null
echo "=== Y700-A79 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
F
sum "force_pio=$(cat /sys/module/spi_geni_qcom/parameters/force_pio 2>/dev/null) chunk-default=$(cat $CHUNK 2>/dev/null)"
sum "boot: nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d) nvt-end=$(grep -c 'NVT-FW end' $SHM/d) validated=$(grep -c 'validated firmware' $SHM/d) snapshot=$(grep -c 'CRC snapshot' $SHM/d) timedout=$(grep -c 'SPI transfer timed out' $SHM/d)"
sum "boot input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
sum "-- boot nvt lines --"
lines "$SHM/d" 8 >> "$SUM" 2>/dev/null
F

find_touch() {
	EV=""
	for i in /sys/class/input/event*; do
		[ -e "$i/device/name" ] || continue
		nm=$(cat "$i/device/name" 2>/dev/null)
		case "$nm" in
		*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) EV=${i##*/} ;;
		esac
	done
}
find_touch
[ -n "$EV" ] 2>/dev/null && sum "boot-touch=YES event=$EV"
step bootlog
if [ -z "$EV" ] 2>/dev/null; then
	m "A79-MARK-1 no-boot-touch retry-with-16KiB-chunks up=$(UP)"
	echo 16384 > "$CHUNK" 2>/dev/null
	sum "chunk-set=$(cat $CHUNK 2>/dev/null)"
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/unbind 2>/dev/null
	done
	sleep 3
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/bind 2>/dev/null
	done
	sleep 10
	dmesg > "$SHM/d2" 2>/dev/null
	sum "chunk-run: nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d2) nvt-end=$(grep -c 'NVT-FW end' $SHM/d2) snapshot=$(grep -c 'CRC snapshot' $SHM/d2) timedout=$(grep -c 'SPI transfer timed out' $SHM/d2)"
	sum "-- chunk-run nvt lines --"
	lines "$SHM/d2" 10 >> "$SUM" 2>/dev/null
	find_touch
	F
fi
sum "final-event=${EV:-NONE}"
if [ -n "$EV" ] 2>/dev/null; then
	m "A79-MARK-2 TOUCH-UP event=$EV up=$(UP)"
	( timeout 26 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 12 ]; do
		m "TOUCHNOW $i swipe-with-one-finger"
		i=$((i + 1))
		sleep 2
	done
	wait $CAT 2>/dev/null
	sz=$(wc -c < "$SHM/events.bin" 2>/dev/null)
	sz=${sz:-0}
	m "A79-MARK-3 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
else
	m "A79-MARK-2 no-event-device"
	sum "events-bytes=NONE"
fi
F
m "A79-MARK-4 read-the-card-when-this-stops up=$(UP)"
step exit