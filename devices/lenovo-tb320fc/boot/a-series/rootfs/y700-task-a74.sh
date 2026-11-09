#!/bin/sh
# A74: one question - is the QUP SE DMA path what resets the board?
# A73 got through the reset line and the trim ID read and died at the first
# firmware write, which is the first SPI transfer bigger than the SE FIFO and
# therefore the first one the master runs as GENI_SE_DMA.  A74 has a
# force_pio switch in spi-geni-qcom, so this round drives the same download
# with PIO first (the thing that should work), captures whatever the chip says,
# and only then re-runs it with DMA to confirm which path kills the board.
# Everything that matters is printed on the panel; the card only gets a few
# hundred bytes because SD writes cost 20 s of mmc timeouts here.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A74'
CARD=/mnt/card
S=$CARD/y700-a74-step.txt
SUM=$CARD/y700-a74-summary.txt
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
: > "$SHM/new"

prev=0
fk() {
	dmesg > "$SHM/k" 2>/dev/null
	n=$(wc -l < "$SHM/k" 2>/dev/null)
	n=${n:-0}
	if [ "$n" -gt "$prev" ] 2>/dev/null; then
		sed -n "$((prev + 1)),\$p" "$SHM/k" >> "$SHM/new"
		prev=$n
	fi
}
key() {
	fk
	grep -iE 'Y700-GENI|NVT-FW|NVT-STAGE|novatek|nt36523|validated|firmware|trim|crc|download|error|fail|timeout' "$SHM/new" 2>/dev/null | tail -6 > "$SHM/key"
	m "KEY $(E "$SHM/key")"
	}

m "START up=$(UP) card=$CARDOK"
fk
PIODIR=""
STAGEDIR=""
CHUNKDIR=""
LIMITDIR=""
for d in /sys/module/*/parameters; do
	[ -e "$d/force_pio" ] && PIODIR=$d
	[ -e "$d/nvt_stage" ] && STAGEDIR=$d
	[ -e "$d/nvt_fw_chunk" ] && CHUNKDIR=$d
	[ -e "$d/nvt_fw_bytes" ] && LIMITDIR=$d
done
step params
echo "=== Y700-A74 $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
sum "pio-param=${PIODIR:-MISSING} cur=$(cat $PIODIR/force_pio 2>/dev/null)"
sum "stage-param=${STAGEDIR:-MISSING} chunk-param=${CHUNKDIR:-MISSING} limit-param=${LIMITDIR:-MISSING}"
sum "spi=$(LS /sys/bus/spi/devices) input=$(LS /sys/class/input)"
BEFORE=$(ls /dev/input 2>/dev/null | busybox tr '\n' ' ')
sum "event-before=$BEFORE"
m "PIO-DIR=$PIODIR STAGE-DIR=$STAGEDIR"
fk

# ---- the fix attempt: PIO for every SPI transfer -------------------------
step pio-on
if [ -n "$PIODIR" ] 2>/dev/null; then
	echo 1 > "$PIODIR/force_pio" 2>"$SHM/pe"
	m "FORCE_PIO now=$(cat $PIODIR/force_pio 2>/dev/null) rc=$? err=$(E "$SHM/pe")"
	sum "force_pio-set=$(cat $PIODIR/force_pio 2>/dev/null)"
else
	m "FORCE_PIO parameter missing, cannot force PIO"
	sum "force_pio-set=MISSING"
fi
F

# ---- firmware into RAM, install, nothing big onto the card --------------
step fwfetch
BIN=$SHM/y700-fwfetch
cp -f /mnt/card/y700-fwfetch "$BIN" 2>/dev/null
chmod +x "$BIN" 2>/dev/null
timeout 130 "$BIN" /dev/sda10 0 "$SHM/fw" > "$SHM/fwout" 2>&1
rc=$?
m "FWFETCH rc=$rc hits=$(grep -c '^LP HIT' $SHM/fwout 2>/dev/null) up=$(UP)"
NOVT=$SHM/fw/novatek_ts_fw.bin
mkdir -p /lib/firmware/novatek 2>/dev/null
rm -f /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
cp -f "$NOVT" /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
sync
sum "fwfetch-rc=$rc src=$(wc -c < "$NOVT" 2>/dev/null) installed=$(LS /lib/firmware/novatek)"
F

# ---- stage 3 over PIO ----------------------------------------------------
DRV=/sys/bus/spi/drivers/novatek-nt36523n-spi
do_unbind() {
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > "$DRV/unbind" 2>/dev/null
	done
}
do_bind() {
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > "$DRV/bind" 2>"$SHM/be"
		m "BOUND ${d##*/} rc=$? up=$(UP)"
	done
}

step pio-stage3
[ -n "$CHUNKDIR" ] && echo 0 > "$CHUNKDIR/nvt_fw_chunk" 2>/dev/null
[ -n "$LIMITDIR" ] && echo 0 > "$LIMITDIR/nvt_fw_bytes" 2>/dev/null
[ -n "$STAGEDIR" ] && echo 3 > "$STAGEDIR/nvt_stage" 2>/dev/null
m "A74-MARK-1 PIO-FIRMWARE-DOWNLOAD-NOW up=$(UP)"
do_unbind
sleep 2
do_bind
sleep 6
m "A74-MARK-2 pio-stage3-plus-6s up=$(UP)"
sleep 4
key
m "PIO-STAGE3 pio=$(cat $PIODIR/force_pio 2>/dev/null) fw=$(grep -c 'NVT-FW end' $SHM/new 2>/dev/null) input=$(LS /sys/class/input)"
sum "pio-run: fwend=$(grep -c 'NVT-FW end' $SHM/new 2>/dev/null) err=$(grep -icE 'fail|error|timeout' $SHM/new 2>/dev/null) input=$(LS /sys/class/input)"
sum "pio-lines=$(E "$SHM/key")"
F

# ---- touch capture -------------------------------------------------------
EV=""
for e in /sys/class/input/event*; do
	[ -e "$e/device/name" ] || continue
	nm=$(cat "$e/device/name" 2>/dev/null)
	case "$nm" in
	*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) EV=${e##*/} ;;
	esac
done
[ -n "$EV" ] 2>/dev/null || {
	for e in /dev/input/event*; do
		[ -e "$e" ] || continue
		nm=${e##*/}
		case " $BEFORE " in
		*" $nm "*) ;;
		*) EV=$nm ;;
		esac
	done
}
step touch
sum "touch-event-dev=${EV:-NONE}"
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
	m "A74-MARK-3 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
	hexdump -v -e '6/4 "%d " "\n"' "$SHM/events.bin" 2>/dev/null | head -8 > "$SHM/evhex"
	sum "events-head=$(E "$SHM/evhex")"
else
	m "A74-MARK-3 no-event-device"
fi
F

# ---- flushed: now the control test, put DMA back on ----------------------
step flush-summary
m "A74-MARK-4 summary-on-card up=$(UP)"
F
step dma-stage3
if [ -n "$PIODIR" ] 2>/dev/null; then
	echo 0 > "$PIODIR/force_pio" 2>/dev/null
	m "FORCE_PIO back-to-DMA now=$(cat $PIODIR/force_pio 2>/dev/null) up=$(UP)"
	sum "dma-run: force_pio=$(cat $PIODIR/force_pio 2>/dev/null)"
	fk
	m "A74-MARK-5 DMA-FIRMWARE-DOWNLOAD-NOW-board-may-reset up=$(UP)"
	do_unbind
	sleep 2
	do_bind
	sleep 8
	key
	m "DMA-STAGE3 SURVIVED input=$(LS /sys/class/input)"
	sum "dma-survived=1 input=$(LS /sys/class/input)"
	sum "dma-lines=$(E "$SHM/key")"
	F
else
	sum "dma-run=SKIPPED no force_pio parameter"
fi

step mark
echo thaw > /sys/kernel/debug/y700-con 2>/dev/null
m "A74-MARK-6 round-finished up=$(UP)"
sleep 3
m "A74-MARK-7 read-the-card-when-this-stops up=$(UP)"
step exit