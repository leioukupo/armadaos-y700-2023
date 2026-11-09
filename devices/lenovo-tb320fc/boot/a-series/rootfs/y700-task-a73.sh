#!/bin/sh
# A73: find out what actually resets the board when the touchscreen is poked.
# A71/A72 both died ~1 s after binding spi0.0 with a real firmware installed and
# neither left a line about what was in flight, because y700fb turned the
# console off at 2.2 s and the SD card swallowed the logs in mmc timeouts.  A73
# walks the driver stage parameter (0 no SPI/no reset, 1 reset line + engine
# reset, 2 trim ID read, 3 firmware download) with a card marker written before
# each stage, so whatever the last stage on the card is, that is the action that
# killed it - and the panel now shows the kernel's own lines for the same thing.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A73'
CARD=/mnt/card
S=$CARD/y700-a73-step.txt
CARD=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
E() { head -c 200 "$1" 2>/dev/null | tr '\n' ' '; }
BIG() { head -c 1400 "$1" 2>/dev/null | tr '\n' '|'; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }

# dev_info() lines are below loglevel=4, so nothing the touch driver says would
# reach the panel; raise the console level and keep the earlycon drawing.
echo 7 4 1 7 > /proc/sys/kernel/printk 2>/dev/null

[ -d /mnt/card ] && mount -o remount,rw /mnt/card 2>/dev/null
[ -e /mnt/card ] && CARD=1

mkdir -p /dev/shm 2>/dev/null
mount -t tmpfs -o size=900m tmpfs /dev/shm 2>/dev/null
SHM=/dev/shm
if ! touch "$SHM/.probe" 2>/dev/null; then
	mkdir -p /tmp/y700
	SHM=/tmp/y700
	touch "$SHM/.probe" 2>/dev/null
fi
rm -f "$SHM/.probe"

R=$SHM/report.txt
T=$SHM/kmsg.txt
: > "$R"
w() { echo "$*" >> "$R" 2>/dev/null; }

sh -n "$0" 2>"$SHM/syn"
selfcheck_rc=$?

prev=$(dmesg 2>/dev/null | wc -l)
prev=${prev:-0}
fk() {
	dmesg > "$SHM/k" 2>/dev/null
	n=$(wc -l < "$SHM/k" 2>/dev/null)
	n=${n:-0}
	if [ "$n" -gt "$prev" ] 2>/dev/null; then
		sed -n "$((prev + 1)),\$p" "$SHM/k" >> "$T"
		prev=$n
	fi
}
(
	i=0
	while [ $i -lt 240 ]; do
		fk
		i=$((i + 1))
		sleep 1
	done
) &
MIRROR=$!

cpk() {
	cp -f "$R" "$CARD/y700-a73-report.txt" 2>/dev/null
	cp -f "$T" "$CARD/y700-a73-kmsg.txt" 2>/dev/null
	F
}

m "START up=$(UP) card=$CARD mirror=$MIRROR selfcheck=$selfcheck_rc"
fk
step start
w "===== Y700-A73 (stage walk: reset line vs SPI vs firmware download) ====="
w "cmdline=$(cat /proc/cmdline 2>/dev/null)"
w "kernel=$(uname -r) up=$(UP) shm=$SHM printk=$(cat /proc/sys/kernel/printk 2>/dev/null)"
w "spi-devices=$(LS /sys/bus/spi/devices)"
w "module-dirs=$(ls /sys/module 2>/dev/null | grep -iE 'novatek|nt36523|geni|spi' | busybox tr '\n' '|')"
STAGEDIR=""
for d in /sys/module/*; do
	[ -e "$d/parameters/nvt_stage" ] && STAGEDIR=$d/parameters
done
w "stage-param=$(ls $STAGEDIR 2>/dev/null | busybox tr '\n' '|') cur=$(cat $STAGEDIR/nvt_stage 2>/dev/null)"
w "fb-consume=$(dmesg 2>/dev/null | grep -c 'console kept on the simplefb earlycon')"
w "input-before=$(LS /sys/class/input)"
event_before=$(ls /dev/input 2>/dev/null | busybox tr '\n' ' ')
w "event-before=$event_before"
F

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

# ---- 1: firmware into RAM, nothing onto the card yet ---------------------
step fwfetch
BIN=$SHM/y700-fwfetch
cp -f /mnt/card/y700-fwfetch "$BIN" 2>/dev/null
chmod +x "$BIN" 2>/dev/null
m "FWFETCH start up=$(UP)"
timeout 130 "$BIN" /dev/sda10 0 "$SHM/fw" > "$SHM/fwout" 2>&1
rc=$?
m "FWFETCH done rc=$rc hits=$(grep -c '^LP HIT' $SHM/fwout 2>/dev/null) up=$(UP)"
w "fw-outdir=$(LS $SHM/fw)"
NOVT=$SHM/fw/novatek_ts_fw.bin
w "install-src=$NOVT bytes=$(wc -c < "$NOVT" 2>/dev/null) sha=$(sha256sum "$NOVT" 2>/dev/null | cut -c1-64)"
mkdir -p /lib/firmware/novatek 2>/dev/null
rm -f /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
cp -f "$NOVT" /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
sync
w "installed=$(LS /lib/firmware/novatek)"
F

# ---- 2: the stage walk ---------------------------------------------------
for st in 0 1 2 3; do
	step "stage$st"
	if [ -n "$STAGEDIR" ] 2>/dev/null; then
		echo $st > "$STAGEDIR/nvt_stage" 2>"$SHM/se"
		w "stage-set=$st rc=$? err=$(E "$SHM/se") now=$(cat $STAGEDIR/nvt_stage 2>/dev/null)"
	else
		w "stage-set=$st SKIPPED no nvt_stage parameter"
	fi
	b4=$(dmesg 2>/dev/null | wc -l)
	do_unbind
	sleep 2
	do_bind
	m "STAGE-$st bound up=$(UP)"
	sleep 3
	m "STAGE-$st +3s up=$(UP)"
	sleep 3
	m "STAGE-$st +6s up=$(UP)"
	dmesg 2>/dev/null | sed -n "$((b4 + 1)),\$p" | grep -iE "novatek|nt36523|nvt|firmware|validated|invalid|download|trim|stage|error|probe|reset" | head -25 > "$SHM/st$st"
	w "=== stage $st log ==="
	w "stage-$st=$(BIG "$SHM/st$st")"
	w "stage-$st input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
	F
	cp -f "$R" "$CARD/y700-a73-report.txt" 2>/dev/null
	F
done

# ---- 3: touch capture if stage 3 produced an input device ---------------
step find-touch
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
		case " $event_before " in
		*" $nm "*) ;;
		*) EV=$nm ;;
		esac
	done
}
w "touch-event-dev=$EV"
cat /proc/bus/input/devices > "$SHM/input.txt" 2>/dev/null
w "input-devices=$(BIG "$SHM/input.txt")"
F

step touch
if [ -n "$EV" ] 2>/dev/null; then
	( timeout 40 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 19 ]; do
		m "TOUCHNOW $i swipe-the-screen-with-one-finger"
		i=$((i + 1))
		sleep 2
	done
	wait $CAT 2>/dev/null
	sz=$(wc -c < "$SHM/events.bin" 2>/dev/null)
	sz=${sz:-0}
	w "events-bytes=$sz events=$((sz / 24))"
	hexdump -v -e '6/4 "%d " "\n"' "$SHM/events.bin" 2>/dev/null | head -120 > "$SHM/evhex"
	w "events-head=$(BIG "$SHM/evhex")"
else
	w "no-touch-event-device"
fi
F

step mark
echo thaw > /sys/kernel/debug/y700-con 2>/dev/null
m "A73-MARK-1 round-finished-up=$(UP)"
sleep 3
m "A73-MARK-2 read-the-card-when-this-stops up=$(UP)"

kill $MIRROR 2>/dev/null
fk
step flush
cpk
cp -f "$SHM/evhex" "$CARD/y700-a73-events.txt" 2>/dev/null
cp -f "$SHM/events.bin" "$CARD/y700-a73-events.bin" 2>/dev/null
cp -f "$SHM/fw/novatek_ts_fw.bin" "$CARD/y700-a73-ts_fw.bin" 2>/dev/null
F
w "final-card=$(LS $CARD/y700-a73*)"
step exit