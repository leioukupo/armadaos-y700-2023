#!/bin/sh
# A78: same A76 kernel - the card runs a two-phase test in one user action.
#
# A76 (booted straight after "fastboot reboot", i.e. a warm boot) downloaded the
# firmware but never got a CRC snapshot and never registered an input device.
# A77, a cold power-on with the very same image, printed both snapshots,
# registered the touchscreen by itself (event2) and delivered 25112 events.  So
# the variable is the state the touch IC is left in, not the kernel.  A78 proves
# that on one card: phase 1 (cold) captures the boot evidence, then reboots the
# tablet by itself; phase 2 (warm) captures its own evidence and samples touch.
# The card gets a few KB per phase, nothing else.  The phase file only ever moves`n# cold -> warm -> done, so a task that runs on every boot can never loop.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A78'
CARD=/mnt/card
S=$CARD/y700-a78-step.txt
SUM=$CARD/y700-a78-summary.txt
PH=$CARD/y700-a78-phase.txt
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
mount -t tmpfs -o size=300m tmpfs /dev/shm 2>/dev/null
SHM=/dev/shm
if ! touch "$SHM/.probe" 2>/dev/null; then
	mkdir -p /tmp/y700
	SHM=/tmp/y700
	touch "$SHM/.probe" 2>/dev/null
fi
rm -f "$SHM/.probe"

PHASE=cold
[ "$CARDOK" = 1 ] && PHASE=$(head -c 16 "$PH" 2>/dev/null)
case "$PHASE" in
warm) : ;;
done) : ;;
*) PHASE=cold ;;
esac

m "START up=$(UP) card=$CARDOK phase=$PHASE"
step state
dmesg > "$SHM/d" 2>/dev/null
echo "=== Y700-A78 phase=$PHASE $(uname -r) up=$(UP) ===" >> "$SUM" 2>/dev/null
F
sum "force_pio=$(cat /sys/module/spi_geni_qcom/parameters/force_pio 2>/dev/null) input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
sum "nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d) nvt-end=$(grep -c 'NVT-FW end' $SHM/d) validated=$(grep -c 'validated firmware' $SHM/d) snapshot=$(grep -c 'CRC snapshot' $SHM/d) snapshot-fail=$(grep -c 'CRC snapshot failed' $SHM/d)"
grep -aiE 'nt36523|NVT-|geni_spi 990000|CRC snapshot|firmware .* failed' "$SHM/d" 2>/dev/null | tail -n 12 | busybox cut -c1-150 > "$SHM/g"
sum "-- nvt lines (last 12) --"
cat "$SHM/g" >> "$SUM" 2>/dev/null
F

EV=""
for i in /sys/class/input/event*; do
	[ -e "$i/device/name" ] || continue
	nm=$(cat "$i/device/name" 2>/dev/null)
	case "$nm" in
	*nt36523*|*novatek*|*NVT*|*Touchscreen*|*touch*) EV=${i##*/} ;;
	esac
done
sum "touch-event=${EV:-NONE}"
if [ -n "$EV" ] 2>/dev/null; then
	m "A78-MARK-1 $PHASE-TOUCH-UP event=$EV up=$(UP)"
	( timeout 24 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 11 ]; do
		m "TOUCHNOW $i swipe-with-one-finger"
		i=$((i + 1))
		sleep 2
	done
	wait $CAT 2>/dev/null
	sz=$(wc -c < "$SHM/events.bin" 2>/dev/null)
	sz=${sz:-0}
	m "A78-MARK-2 events-bytes=$sz"
	sum "events-bytes=$sz events=$((sz / 24))"
else
	m "A78-MARK-1 $PHASE-NO-TOUCH up=$(UP)"
	sum "events-bytes=NONE"
fi
F

if [ "$PHASE" = cold ] 2>/dev/null; then
	if [ "$CARDOK" = 1 ] 2>/dev/null; then
		echo warm > "$PH" 2>/dev/null
		F
		m "A78-MARK-3 cold-done rebooting-for-warm-phase up=$(UP)"
		sum "phase1=cold rebooting=$(date -u 2>/dev/null)"
		F
		sleep 3
		busybox reboot 2>/dev/null
		reboot 2>/dev/null
		m "A78-MARK-4 reboot-FAILED stay-here up=$(UP)"
	else
		m "A78-MARK-3 cold-no-card stop-here up=$(UP)"
	fi
else
	echo done > "$PH" 2>/dev/null
	F
	m "A78-MARK-3 warm-phase-done read-the-card up=$(UP)"
fi
step exit