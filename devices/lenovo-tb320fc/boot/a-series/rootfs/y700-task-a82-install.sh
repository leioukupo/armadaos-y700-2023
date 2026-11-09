#!/bin/sh
# A82 install task: copy the staged ArmadaOS root (armada-root.img, sitting on the
# card's btrfs partition p3) onto UFS partition 16 (linuxroot), so the next boot
# can switch_root into a real distribution.
#
# Hard gates, in order, before a single byte is written:
#   * our root must be the SD card, never /dev/sda16 - writing the target while it
#     is mounted rw as / is how a root dies mid-copy;
#   * the card must hold y700-install.txt with INSTALL_ARMADA_GO;
#   * p16 must be the size the A40 surgery created (675529368 sectors), so it
#     cannot be another LUN's partition;
#   * the staged image must be present, plausibly sized, and end with an ext4
#     superblock.
# Everything is logged to the card and, because fbcon owns the panel (A81), also
# printed on the glass, so the install is readable without a serial cable.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A82-INSTALL'
CARD=/mnt/card
S=$CARD/y700-a82-step.txt
SUM=$CARD/y700-a82-summary.txt
WANT_SZS=675529368

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
big() { echo "<6>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
step() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }

m "START up=$(UP)"
big "START installing ArmadaOS up=$(UP)"
echo "=== Y700-A82 install up=$(UP) ===" > "$SUM" 2>/dev/null
F

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
sum "rootdev=$RD"
case "$RD" in
	*mmcblk*) : ;;
	*) m "REFUSE root is $RD, not the card - not touching sda16"; big "REFUSE root=$RD not card"; step exit; exit 1 ;;
esac

GO=""
[ -f "$CARD/y700-install.txt" ] && GO=$(tr -d '\r' < "$CARD/y700-install.txt")
case "$GO" in
	*INSTALL_ARMADA_GO*) : ;;
	*) m "REFUSE y700-install.txt has no INSTALL_ARMADA_GO (got [$GO])"; big "REFUSE no install marker"; step exit; exit 1 ;;
esac

[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
sum "sda16 sectors=$SZS want=$WANT_SZS"
if [ "$SZS" != "$WANT_SZS" ] ; then
	m "REFUSE sda16 size $SZS != $WANT_SZS"
	big "REFUSE sda16 size mismatch"
	step exit
	exit 1
fi

mkdir -p /mnt/p3 2>/dev/null
P3=""
for d in /dev/mmcblk0p3 /dev/mmcblk1p3 /dev/mmcblk2p3 ; do
	[ -b "$d" ] || continue
	mount -o ro "$d" /mnt/p3 2>/dev/null && { P3="$d"; break; }
done
sum "p3=$P3"
if [ -z "$P3" ] ; then
	m "REFUSE cannot mount the card p3 (btrfs) - no staged image"
	big "REFUSE no p3"
	step exit
	exit 1
fi
IMG=/mnt/p3/armada-root.img
BYTES=$(wc -c < "$IMG" 2>/dev/null)
BYTES=${BYTES:-0}
sum "image=$IMG bytes=$BYTES"
if [ "$BYTES" -lt 4294967296 ] ; then
	m "REFUSE image too small ($BYTES)"
	big "REFUSE image too small"
	step exit
	exit 1
fi
m "image present: $BYTES bytes on $P3"

big "dd $BYTES bytes to /dev/sda16"
step dd-start
GIB=1073741824
NCH=$(( (BYTES + GIB - 1) / GIB ))
i=0
RC=0
while [ $i -lt $NCH ] ; do
	dd if="$IMG" of=/dev/sda16 bs=1M count=1024 skip=$i oflag=direct conv=notrunc 2>/dev/null
	if [ $? != 0 ] ; then
		dd if="$IMG" of=/dev/sda16 bs=1M count=1024 skip=$i conv=notrunc 2>/dev/null
		RC=$?
	else
		RC=0
	fi
	[ "$RC" = "0" ] || break
	i=$((i + 1))
	F
	sum "dd chunk $i/$NCH rc=$RC up=$(UP)"
	m "dd $i/$NCH up=$(UP)"
	big "dd $i/$NCH GiB done ($(( i * 100 / NCH ))%) up=$(UP)"
done
step dd-done
if [ "$RC" != "0" ] ; then
	m "dd FAILED rc=$RC at chunk $i"
	big "dd FAILED rc=$RC"
	sum "dd rc=$RC at chunk $i"
	step exit
	exit 1
fi
F
big "dd finished $NCH GiB, verifying"

mkdir -p /mnt/chk 2>/dev/null
mount -t ext4 -o ro /dev/sda16 /mnt/chk 2>/dev/null
MR=$?
sum "verify mount rc=$MR"
if [ "$MR" = "0" ] ; then
	sum "osrelease=$(head -c 80 /mnt/chk/usr/lib/os-release 2>/dev/null | busybox tr '\n' ' ')"
	sum "init=$(ls -l /mnt/chk/sbin/init 2>/dev/null) systemd=$(ls -l /mnt/chk/usr/lib/systemd/systemd 2>/dev/null)"
	sum "files=$(ls /mnt/chk 2>/dev/null | busybox tr '\n' ' ')"
	sum "health-unit=$(ls /mnt/chk/etc/systemd/system/y700-health.service 2>/dev/null)"
	umount /mnt/chk 2>/dev/null
else
	m "verify FAILED cannot mount sda16 after dd"
	big "verify FAILED no ext4 on sda16"
fi

# The card asked for a card-first boot; hand the next boot back to UFS.
echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt" 2>/dev/null
F
sum "marker y700-ufs.txt now: $(cat "$CARD/y700-ufs.txt" 2>/dev/null)"
m "DONE chunks=$NCH up=$(UP)"
step exit
big "INSTALL DONE - rebooting in 8s"
sleep 8
reboot 2>/dev/null
m "reboot did not happen, holding"
sleep 300