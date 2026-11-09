#!/bin/sh
# A76-prep: A75 left the working firmware inside the UFS rootfs
# (/lib/firmware/novatek/lenovo-tb320fc.bin, 196608 B).  Copy it out to the card
# once so the build machine can put it into the initramfs, which is the only
# place the boot-time probe of a built-in driver can see a firmware file.  192 KB
# onto this card costs a few seconds of mmc timeouts, which is affordable for a
# one-time copy.  Nothing else is written to the card.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A76P'
CARD=/mnt/card
S=$CARD/y700-a76p-step.txt
SUM=$CARD/y700-a76p-summary.txt
OUT=$CARD/y700-firmware-lenovo-tb320fc.bin
FW=/lib/firmware/novatek/lenovo-tb320fc.bin

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
mkdir -p /dev/shm 2>/dev/null
mount -t tmpfs -o size=900m tmpfs /dev/shm 2>/dev/null
SHM=/dev/shm
if ! touch "$SHM/.probe" 2>/dev/null; then
	mkdir -p /tmp/y700
	SHM=/tmp/y700
fi
rm -f "$SHM/.probe"

m "START up=$(UP) fw=$(ls -l $FW 2>/dev/null | busybox awk '{print $5}')"
step state
echo "=== Y700-A76P $(uname -r) up=$(UP) ===" > "$SUM" 2>/dev/null
sum "fw-src=$FW bytes=$(wc -c < $FW 2>/dev/null)"
sum "root=$(mount 2>/dev/null | busybox grep ' / ' | busybox tr '\n' '|')"
sum "input=$(LS /sys/class/input) events=$(ls /dev/input 2>/dev/null | busybox tr '\n' '|')"
dmesg > "$SHM/d" 2>/dev/null
sum "boot-nvt-begin=$(grep -c 'NVT-FW begin' $SHM/d 2>/dev/null) boot-nvt-end=$(grep -c 'NVT-FW end' $SHM/d 2>/dev/null)"
sum "boot-validated=$(grep -c 'validated firmware' $SHM/d 2>/dev/null) boot-crcsnap=$(grep -c 'CRC snapshot' $SHM/d 2>/dev/null)"
sum "boot-genimode=$(grep -m1 'Y700-GENI xfer' $SHM/d 2>/dev/null)"
grep -iE 'NVT-FW|validated firmware|CRC snapshot|Y700-GENI xfer|nt36523' "$SHM/d" 2>/dev/null | tail -5 > "$SHM/key"
m "KEY $(E "$SHM/key")"
rm -f "$SHM/d"
F

step copy-fw
cp -f "$FW" "$OUT" 2>/dev/null
F
sum "copied-bytes=$(wc -c < $OUT 2>/dev/null) sha=$(sha256sum $OUT 2>/dev/null | busybox cut -c1-64)"
m "A76P-MARK-1 fw-on-card bytes=$(wc -c < $OUT 2>/dev/null) sha=$(sha256sum $OUT 2>/dev/null | busybox cut -c1-16) up=$(UP)"
F
sleep 2
m "A76P-MARK-2 read-the-card-when-this-stops up=$(UP)"
step exit