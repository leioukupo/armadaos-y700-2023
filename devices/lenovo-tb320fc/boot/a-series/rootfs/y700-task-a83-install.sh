#!/bin/sh
# A83 install task: copy the staged ArmadaOS root (armada-root.img, sitting on the
# card's btrfs partition p3) onto UFS partition 16 (linuxroot), so the next boot
# can switch_root into a real distribution.
#
# Hard gates, in order, before a single byte is written:
#   * our root must be the SD card, never /dev/sda16 - writing the target while it
#     is mounted rw as / is how a root dies mid-copy;
#   * the card must hold y700-install.txt with INSTALL_ARMADA_GO;
#   * p16 must be the size the A40 surgery created (675529368 sectors), so it
#     cannot be another LUN's partition;
#   * the staged image must exist and be plausibly sized.
# Everything is logged to the card and, because fbcon owns the panel (A81), also
# printed on the glass, so the install is readable without a serial cable.
#
# A82 -> A83 (the A82 round passed every gate, mounted p3, then looked hung):
#   * the image size came from "wc -c < $IMG", which reads all 15 GiB through the
#     slow SD slot before dd starts - size it from the inode instead;
#   * p3 is mounted with an explicit -t btrfs, so busybox does not probe erofs
#     first (that is where "cant find valid erofs superblock" on the panel came from);
#   * progress is per 512 MiB instead of per 1 GiB, so the panel keeps moving and a
#     stall is obvious instead of deniable.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A83-INSTALL'
CARD=/mnt/card
S=$CARD/y700-a83-step.txt
SUM=$CARD/y700-a83-summary.txt
WANT_SZS=675529368
CH_MIB=512

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
big() { echo "<6>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
step() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; m "STEP $1 up=$(UP)"; }
sum() { echo "$*" >> "$SUM" 2>/dev/null; F; }

m "START up=$(UP)"
big "START installing ArmadaOS up=$(UP)"
echo "=== Y700-A83 install up=$(UP) ===" > "$SUM" 2>/dev/null
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
	mount -t btrfs -o ro "$d" /mnt/p3 2>/dev/null && { P3="$d"; break; }
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
if [ ! -f "$IMG" ] ; then
	m "REFUSE $IMG is missing"
	big "REFUSE no staged image"
	step exit
	exit 1
fi
# Size it from the inode: "wc -c < $IMG" would read the whole 15 GiB off the card
# before a single byte is written, which is exactly what made A82 look hung.
BYTES=$(stat -c %s "$IMG" 2>/dev/null)
[ -n "$BYTES" ] || BYTES=$(busybox stat -c %s "$IMG" 2>/dev/null)
[ -n "$BYTES" ] || BYTES=$(ls -l "$IMG" 2>/dev/null | awk '{print $5}')
BYTES=${BYTES:-0}
sum "image=$IMG bytes=$BYTES"
if [ "$BYTES" -lt 4294967296 ] ; then
	m "REFUSE image too small ($BYTES)"
	big "REFUSE image too small"
	step exit
	exit 1
fi
m "image present: $BYTES bytes on $P3"

CH_BYTES=$((CH_MIB * 1048576))
NCH=$(( (BYTES + CH_BYTES - 1) / CH_BYTES ))
big "dd $BYTES bytes -> /dev/sda16 ($NCH chunks of $CH_MIB MiB)"
step dd-start
i=0
RC=0
while [ $i -lt $NCH ] ; do
	SKIP=$(( i * CH_MIB ))
	dd if="$IMG" of=/dev/sda16 bs=1M count=$CH_MIB skip=$SKIP oflag=direct conv=notrunc 2>/dev/null
	RC=$?
	if [ "$RC" != "0" ] ; then
		dd if="$IMG" of=/dev/sda16 bs=1M count=$CH_MIB skip=$SKIP conv=notrunc 2>/dev/null
		RC=$?
	fi
	[ "$RC" = "0" ] || break
	i=$((i + 1))
	F
	sum "dd chunk $i/$NCH rc=$RC up=$(UP)"
	m "dd $i/$NCH up=$(UP)"
	big "dd $i/$NCH done ($(( i * 100 / NCH ))%) up=$(UP)"
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
big "dd finished $NCH chunks, verifying"

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