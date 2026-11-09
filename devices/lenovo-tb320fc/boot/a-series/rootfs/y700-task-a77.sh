#!/bin/sh
# A77: same A76 kernel, so no rebuild - the card does the talking.
#
# A76 proved the initramfs fix worked: at boot the driver validated the blob and
# ran the whole SRAM transfer with PIO (Y700-GENI xfer mode=1 force_pio=1 at
# 2.4 s) without resetting the board.  But no input device appeared, and the
# reason is visible in what is MISSING: no "pre-boot CRC snapshot", so
# nvt_poll_dma_copy() (or the transfer itself) failed and probe aborted with a
# "firmware <step> failed" line.  A76 tried to copy those lines to the card and
# failed because the helper takes a file, not a string.  A77 writes the real
# lines: boot stage, then one re-bind, then a second attempt 20 s later, so the
# card says which step breaks and whether the first try poisons the next one.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A77'
CARD=/mnt/card
S=$CARD/y700-a77-step.txt
SUM=$CARD/y700-a77-summary.txt
CARDOK=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }
# dump the interesting dmesg lines from file $1, at most $2 of them, into the
# summary with prefix $3 (each line cut to 130 chars so the card stays small)
dump() {
	f=$1; tag=$2; n=$3
	i=0
	grep -aiE 'nt36523|geni_spi|firmware|NVT-' "$f" 2>/dev/null | head -n 18 > "$SHM/g"
	while [ $i -lt 18 ] && [ $i -lt $n ]; do
		i=$((i + 1))
		line=$(sed -n "${i}p" "$SHM/g" 2>/dev/null)
		[ -n "$line" ] || break
		sum "$tag$i=$(printf '%s' "$line" | busybox cut -c1-130)"
	done
}

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
echo "=== Y700-A77 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
sum "force_pio=$(cat $PIO 2>/dev/null) root=$(mount 2>/dev/null | busybox grep ' / ' | busybox cut -d' ' -f1-3)"
sum "spi=$(LS /sys/bus/spi/devices) input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
sum "boot-nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d) nvt-end=$(grep -c 'NVT-FW end' $SHM/d) validated=$(grep -c 'validated firmware' $SHM/d) snapshot=$(grep -c 'CRC snapshot' $SHM/d)"
sum "boot-genimode=$(grep -m1 -a 'Y700-GENI xfer' $SHM/d | busybox cut -c1-130)"
dump "$SHM/d" bootlog 18
step bootlog

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
sum "boot-event=${EV:-NONE}"
if [ -n "$EV" ] 2>/dev/null; then
	m "A77-MARK-1 BOOT-TOUCH-AUTO event=$EV up=$(UP)"
else
	m "A77-MARK-1 NO-BOOT-TOUCH rebind-1 now up=$(UP)"
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/unbind 2>/dev/null
	done
	sleep 2
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/bind 2>/dev/null
	done
	sleep 8
	find_touch
	sum "rebind1-event=${EV:-NONE} rebind1-nvt-end=$(dmesg 2>/dev/null | grep -c 'NVT-FW end')"
	m "A77-MARK-2 rebind-1 event=${EV:-NONE} up=$(UP)"
fi
step rebind1
if [ -z "$EV" ] 2>/dev/null; then
	sleep 20
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/unbind 2>/dev/null
	done
	sleep 5
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > /sys/bus/spi/drivers/novatek-nt36523n-spi/bind 2>/dev/null
	done
	sleep 10
	find_touch
	dmesg > "$SHM/d3" 2>/dev/null
	sum "rebind2-event=${EV:-NONE}"
	dump "$SHM/d3" rebindlog 18
	m "A77-MARK-3 rebind-2 event=${EV:-NONE} up=$(UP)"
fi
step rebind2
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
	m "A77-MARK-4 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
else
	m "A77-MARK-4 no-event-device"
	sum "events-bytes=NONE"
fi
F
m "A77-MARK-5 read-the-card-when-this-stops up=$(UP)"
step exit