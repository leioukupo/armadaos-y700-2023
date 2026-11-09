#!/bin/sh
# A80: 16 KiB is now the built-in chunk size, so the boot-time download should
# win the spi_transfer_wait() race on its own.  This round nothing is poked from
# userspace: the question is only whether the touchscreen registers during boot,
# by itself, with no re-bind.  chunk-default must read 16384 (that proves the
# A80 image is the one running), and snapshot=2 / timedout=0 is the pass line.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A80'
CARD=/mnt/card
S=$CARD/y700-a80-step.txt
SUM=$CARD/y700-a80-summary.txt
CARDOK=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }
lines() { grep -aiE 'nt36523|NVT-|CRC snapshot|firmware running|finger input|timed out|firmware .* failed' "$1" 2>/dev/null | tail -n $2 | busybox cut -c1-150; }

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
echo "=== Y700-A80 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
F
sum "force_pio=$(cat /sys/module/spi_geni_qcom/parameters/force_pio 2>/dev/null) chunk-default=$(cat $CHUNK 2>/dev/null) (expect 16384)"
sum "boot: nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d) nvt-end=$(grep -c 'NVT-FW end' $SHM/d) validated=$(grep -c 'validated firmware' $SHM/d) snapshot=$(grep -c 'CRC snapshot' $SHM/d) timedout=$(grep -c 'SPI transfer timed out' $SHM/d)"
sum "boot input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
sum "-- boot nvt lines --"
lines "$SHM/d" 10 >> "$SUM" 2>/dev/null
F

EV=""
for i in /sys/class/input/event*; do
	[ -e "$i/device/name" ] || continue
	nm=$(cat "$i/device/name" 2>/dev/null)
	case "$nm" in
	*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) EV=${i##*/} ;;
	esac
done
if [ -n "$EV" ] 2>/dev/null; then
	m "A80-MARK-1 BOOT-TOUCH-AUTO event=$EV up=$(UP)"
	sum "boot-touch=auto event=$EV"
else
	m "A80-MARK-1 NO-BOOT-TOUCH up=$(UP)"
	sum "boot-touch=NONE"
fi
step touch
if [ -n "$EV" ] 2>/dev/null; then
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
	m "A80-MARK-2 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
	od -An -tx1 -N 96 "$SHM/events.bin" 2>/dev/null | busybox tr '\n' ' ' | busybox cut -c1-200 > "$SHM/h"
	sum "events-head=$(head -c 200 "$SHM/h" 2>/dev/null)"
else
	m "A80-MARK-2 no-event-device"
	sum "events-bytes=NONE"
fi
F
m "A80-MARK-3 read-the-card-when-this-stops up=$(UP)"
step exit