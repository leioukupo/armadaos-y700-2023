#!/bin/sh
# A72: touch firmware download, isolated.  A71 showed two things: the pick list
# now reaches novatek_ts_fw.bin, and the run died ~155 s later, right after the
# bind - because writing 4.9 MB to the SD card stalled in "mmc0: Timeout waiting
# for hardware interrupt" bursts (42 KB/s) and hung_task_panic fired.  So A72
# keeps every artifact in RAM, writes only a few small files to the card, and
# does the SPI/firmware work at up=17 with a marker before and after each step,
# so a reboot pinpoints the exact action instead of guessing.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A72'
CARD=/mnt/card
R=$SHMRPT
S=/mnt/card/y700-a72-step.txt
CARD=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
E() { head -c 200 "$1" 2>/dev/null | tr '\n' ' '; }
BIG() { head -c 1400 "$1" 2>/dev/null | tr '\n' '|'; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }

[ -d /mnt/card ] && mount -o remount,rw,sync /mnt/card 2>/dev/null
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

# everything lives in RAM; the card only gets small checkpoints
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
	while [ $i -lt 260 ]; do
		fk
		i=$((i + 1))
		sleep 1
	done
) &
MIRROR=$!

# checkpoint: RAM artifacts -> card, gzip where it pays, few bytes written
cpk() {
	cp -f "$R" "$CARD/y700-a72-report.txt" 2>/dev/null
	cat "$T" "$R" 2>/dev/null | busybox gzip -9 > "$CARD/y700-a72-log.gz" 2>/dev/null
	F
}

m "START up=$(UP) card=$CARD mirror=$MIRROR selfcheck=$selfcheck_rc"
fk

step start
w "===== Y700-A72 (fw download isolated: RAM artifacts, tiny card writes) ====="
w "cmdline=$(cat /proc/cmdline 2>/dev/null)"
w "kernel=$(uname -r) up=$(UP) shm=$SHM"
w "spi-devices=$(LS /sys/bus/spi/devices)"
w "spi-drivers=$(LS /sys/bus/spi/drivers)"
w "input-before=$(LS /sys/class/input)"
event_before=$(ls /dev/input 2>/dev/null | busybox tr '\n' ' ')
w "event-before=$event_before"
F

DRV=/sys/bus/spi/drivers/novatek-nt36523n-spi
do_unbind() {
	m "BIND-A pre-unbind up=$(UP)"
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > "$DRV/unbind" 2>/dev/null
	done
	m "BIND-B post-unbind up=$(UP)"
}
do_bind() {
	m "BIND-C pre-bind up=$(UP)"
	for d in /sys/bus/spi/devices/*; do
		[ -d "$d" ] || continue
		echo "${d##*/}" > "$DRV/bind" 2>"$SHM/be"
		m "BIND-D bound ${d##*/} rc=$? up=$(UP)"
	done
}

# ---- 1: get the firmware out of super (RAM only) --------------------------
step fwfetch
BIN=$SHM/y700-fwfetch
cp -f /mnt/card/y700-fwfetch "$BIN" 2>/dev/null
chmod +x "$BIN" 2>/dev/null
w "tool=$(ls -l $BIN 2>/dev/null) md5=$(md5sum $BIN 2>/dev/null | cut -c1-32)"
m "FWFETCH start up=$(UP)"
timeout 130 "$BIN" /dev/sda10 0 "$SHM/fw" > "$SHM/fwout" 2>&1
rc=$?
m "FWFETCH done rc=$rc hits=$(grep -c '^LP HIT' $SHM/fwout 2>/dev/null) up=$(UP)"
w "fw-outdir=$(LS $SHM/fw)"
for f in "$SHM"/fw/*; do
	[ -f "$f" ] || continue
	w "fw-file ${f##*/} bytes=$(wc -c < "$f") tail=$(tail -c3 "$f" | tr -d '\n') sha=$(sha256sum "$f" 2>/dev/null | cut -c1-64)"
done
F

# ---- 2: install the one upstream uses, then bind with markers -------------
step install
NOVT=$SHM/fw/novatek_ts_fw.bin
if [ ! -f "$NOVT" ]; then
	NOVT=$(ls $SHM/fw/*ts_fw.bin 2>/dev/null | head -1)
fi
w "install-src=$NOVT bytes=$(wc -c < "$NOVT" 2>/dev/null)"
mkdir -p /lib/firmware/novatek 2>/dev/null
rm -f /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
cp -f "$NOVT" /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
sync
w "installed=$(LS /lib/firmware/novatek) sha=$(sha256sum /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null | cut -c1-64)"
cpk
F

step rebind
b4=$(dmesg 2>/dev/null | wc -l)
do_unbind
sleep 2
do_bind
m "BIND-E post-bind up=$(UP)"
sleep 2
m "BIND-F +2s up=$(UP)"
sleep 2
m "BIND-G +4s up=$(UP)"
sleep 2
m "BIND-H +6s up=$(UP)"
dmesg 2>/dev/null | sed -n "$((b4 + 1)),\$p" | grep -iE "novatek|nt36523|nvt|firmware|validated|invalid|download|trim|version|error|probe" | head -30 > "$SHM/rb"
w "rebind-log=$(BIG "$SHM/rb")"
w "validated=$(grep -c 'validated firmware' $SHM/rb 2>/dev/null)"
w "invalid=$(grep -c 'invalid firmware' $SHM/rb 2>/dev/null)"
w "dlfail=$(grep -c 'download verification failed' $SHM/rb 2>/dev/null)"
w "input-after=$(LS /sys/class/input)"
event_after=$(ls /dev/input 2>/dev/null | busybox tr '\n' ' ')
w "event-after=$event_after"
cpk
F

# ---- 3: the new input device --------------------------------------------
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

# ---- 4: human in the loop -------------------------------------------------
step touch
if [ -n "$EV" ] 2>/dev/null; then
	( timeout 45 cat "/dev/input/$EV" > "$SHM/events.bin" 2>/dev/null ) &
	CAT=$!
	i=0
	while [ $i -lt 22 ]; do
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
cpk
F

step mark
echo thaw > /sys/kernel/debug/y700-con 2>/dev/null
m "A72-MARK-1 round-finished-up=$(UP)"
sleep 3
m "A72-MARK-2 read-the-card-when-this-stops up=$(UP)"

kill $MIRROR 2>/dev/null
fk
step flush
cpk
cp -f "$SHM/evhex" "$CARD/y700-a72-events.txt" 2>/dev/null
cp -f "$SHM/events.bin" "$CARD/y700-a72-events.bin" 2>/dev/null
cp -f "$SHM/fw/novatek_ts_fw.bin" "$CARD/y700-a72-ts_fw.bin" 2>/dev/null
cp -f "$SHM/fwout" "$CARD/y700-a72-fwfetch.txt" 2>/dev/null
F
w "final-card=$(LS $CARD/y700-a72*)"
cpk
F
m "DONE up=$(UP)"
step exit