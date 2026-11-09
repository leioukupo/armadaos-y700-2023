#!/bin/sh
# A71: touch firmware, correct pick this time.  A70 proved the GENI SPI master
# is up, spi0.0 binds to novatek-nt36523n-spi, and y700-fwfetch pulls real
# Novatek blobs out of the Android super partition (novatek_ts_fw.bin is
# exactly 192 KiB, which is what the driver layout check expects).  A70 only
# failed because the picker sorted by size and chose a 930 KB qdcm_calib JSON.
#
# This round: extract everything, copy every candidate to the card for offline
# analysis, then try them in a fixed preference order (upstream AsphaltOS maps
# novatek_ts_fw.bin -> novatek/lenovo-tb320fc.bin).  A candidate is only
# downloaded to the IC when the driver itself says "validated firmware", so a
# wrong-variant blob is rejected before anything is written to the panel IC.
# Then 45 s of on-screen swipe prompts and a raw event capture from the new
# input device.  Nothing on UFS is written; only /dev/shm, /lib/firmware and
# the SD card.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A71'
R=/mnt/card/y700-a71-report.txt
S=/mnt/card/y700-a71-step.txt
T=/mnt/card/y700-a71-kmsg.txt
FW=/mnt/card/y700-a71-fwfetch.txt
CARD=0

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
w() { echo "$*" >> "$R" 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
E() { head -c 200 "$1" 2>/dev/null | tr '\n' ' '; }
BIG() { head -c 1400 "$1" 2>/dev/null | tr '\n' '|'; }
LS() { ls $* 2>/dev/null | busybox tr '\n' '|'; }
qs() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; }
step() { qs "$1"; m "STEP $1 up=$(UP)"; }

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
	sync
}
(
	i=0
	while [ $i -lt 280 ]; do
		fk
		i=$((i + 1))
		sleep 1
	done
) &
MIRROR=$!
m "START up=$(UP) card=$CARD mirror=$MIRROR selfcheck=$selfcheck_rc"
fk

step start
w "===== Y700-A71 (novatek firmware: correct pick + validated download) ====="
w "cmdline=$(cat /proc/cmdline 2>/dev/null)"
w "kernel=$(uname -r) up=$(UP) shm=$SHM"
F

DRV=/sys/bus/spi/drivers/novatek-nt36523n-spi
DEV=""
for d in /sys/bus/spi/devices/*; do
	[ -d "$d" ] || continue
	DEV=$DEV" ${d##*/}"
done
w "spi-devices=$(LS /sys/bus/spi/devices)"
w "spi-drivers=$(LS /sys/bus/spi/drivers)"
w "driver-dir=$(ls -d $DRV 2>/dev/null)"
w "dev-list=$DEV"
w "input-before=$(LS /sys/class/input)"
w "event-before=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
F

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
		w "bind ${d##*/} rc=$? err=$(E "$SHM/be")"
	done
}

# ---- 1: hunt the firmware inside super ------------------------------------
step fwfetch
BIN=$SHM/y700-fwfetch
cp -f /mnt/card/y700-fwfetch "$BIN" 2>/dev/null
chmod +x "$BIN" 2>/dev/null
w "tool=$(ls -l $BIN 2>/dev/null) md5=$(md5sum $BIN 2>/dev/null | cut -c1-32)"
m "FWFETCH start up=$(UP)"
timeout 130 "$BIN" /dev/sda10 0 "$SHM/fw" > "$SHM/fwout" 2>&1
rc=$?
m "FWFETCH done rc=$rc lines=$(wc -l < $SHM/fwout) up=$(UP)"
cp -f "$SHM/fwout" "$FW" 2>/dev/null
w "fwfetch-cands=$(grep -c '^LP CAND' $SHM/fwout 2>/dev/null) mounts=$(grep -c '^LP MOUNT' $SHM/fwout 2>/dev/null) hits=$(grep -c '^LP HIT' $SHM/fwout 2>/dev/null)"
w "fw-outdir=$(LS $SHM/fw)"
for f in "$SHM"/fw/*; do
	[ -f "$f" ] || continue
	w "fw-file ${f##*/} bytes=$(wc -c < "$f") mod4096=$(( $(wc -c < "$f") % 4096 )) tail=$(tail -c3 "$f" | tr -d '\n') sha=$(sha256sum "$f" 2>/dev/null | cut -c1-64)"
done
F

# ---- 2: keep every candidate on the card for offline analysis -------------
step copy-fw
OUT=/mnt/card/y700-a71-fw
mkdir -p "$OUT" 2>/dev/null
for f in "$SHM"/fw/*; do
	[ -f "$f" ] || continue
	cp -f "$f" "$OUT/" 2>/dev/null
done
w "card-fw-dir=$(LS $OUT)"
F

# ---- 3: fixed preference order, driver decides ----------------------------
step pick
OKFW=""
mkdir -p /lib/firmware/novatek 2>/dev/null
for name in novatek_ts_fw.bin novatek_spi_fw.bin novatek_ts_mp.bin novatek_ts_ultra_fw.bin novatek_ts_ultra_mp.bin; do
	f=$SHM/fw/$name
	[ -f "$f" ] || continue
	sz=$(wc -c < "$f")
	tail=$(tail -c3 "$f" | tr -d '\n')
	if [ "$tail" != "NVT" ] || [ $((sz % 4096)) -ne 0 ]; then
		w "skip $name bytes=$sz tail=$tail"
		continue
	fi
	w "try $name bytes=$sz"
	rm -f /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
	cp -f "$f" /lib/firmware/novatek/lenovo-tb320fc.bin 2>/dev/null
	sync
	b4=$(dmesg 2>/dev/null | wc -l)
	do_unbind
	sleep 2
	do_bind
	sleep 6
	dmesg 2>/dev/null | sed -n "$((b4 + 1)),\$p" | grep -iE "novatek|nt36523|nvt|firmware|invalid|validated|download|trim|version|probe" | head -25 > "$SHM/try"
	cp -f "$SHM/try" "$OUT/log-$name.txt" 2>/dev/null
	w "attempt $name log=$(BIG "$SHM/try")"
	if grep -q "validated firmware" "$SHM/try" 2>/dev/null; then
		OKFW=$name
		w "VALIDATED $name"
		break
	fi
done
w "validated-fw=$OKFW"
dmesg 2>/dev/null | grep -iE "novatek|nt36523|nvt" | tail -40 > "$SHM/nvt"
cp -f "$SHM/nvt" /mnt/card/y700-a71-nvt-dmesg.txt 2>/dev/null
w "nvt-dmesg=$(BIG "$SHM/nvt")"
w "input-after-fw=$(LS /sys/class/input)"
w "event-after-fw=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
F

# ---- 4: the new input device, if the download really worked --------------
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
		case "|$event_before|" in
		*"|$nm|"*) ;;
		*) EV=$nm ;;
		esac
	done
}
w "touch-event-dev=$EV"
cat /proc/bus/input/devices > /mnt/card/y700-a71-input-devices.txt 2>/dev/null
in=$(dmesg 2>/dev/null | grep -ciE "firmware download verification failed")
w "download-verify-fail-lines=$in"
F

# ---- 5: human in the loop -------------------------------------------------
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
	cp -f "$SHM/events.bin" "/mnt/card/y700-a71-events-$EV.bin" 2>/dev/null
	hexdump -v -e '6/4 "%d " "\n"' "$SHM/events.bin" 2>/dev/null | head -120 > "$SHM/evhex"
	w "events-head=$(BIG "$SHM/evhex")"
	cp -f "$SHM/evhex" /mnt/card/y700-a71-events.txt 2>/dev/null
else
	w "no-touch-event-device"
fi
F

step mark
echo thaw > /sys/kernel/debug/y700-con 2>/dev/null
m "A71-MARK-1 round-finished-up=$(UP)"
sleep 3
m "A71-MARK-2 read-the-card-when-this-stops up=$(UP)"

kill $MIRROR 2>/dev/null
step done
m "DONE up=$(UP)"
fk
F
i=0
while [ $i -lt 10 ]; do
	sleep 1
	i=$((i + 1))
done
step exit