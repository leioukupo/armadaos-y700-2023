#!/bin/sh
# A86: A85 already wrote sda16 and every chunk's tail hash matched, but the sample
# loop had its skip/count arguments swapped ("skip count tag" was read as
# "count skip"), so it tried to hash 8 GiB and got cut off by the task timeout
# before it could write UFS_ARMADA_DONE.  This pass does the missing verification
# honestly and commits the marker; it writes nothing to sda16.
#
# Checks: three sampled regions of sda16 against the staged image (64 MiB each, so
# a real comparison instead of 4 MiB noise), a real ext4 mount with the top-level
# listing and os-release printed, then the marker.  Any DIFFER or a failed mount
# leaves y700-ufs.txt exactly as it is and does not reboot.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A86-VERIFY'
CARD=/mnt/card
OUT=$CARD/y700-a86-verify.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
big() { echo "<6>$K $*" > /dev/kmsg 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; F; }

echo "=== Y700-A86 verify+commit up=$(UP) ===" > "$OUT" 2>/dev/null
big "START verify sda16 up=$(UP)"

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
U "rootdev=$RD"
case "$RD" in
	*mmcblk*) : ;;
	*) m "REFUSE root is $RD, not the card"; big "REFUSE root=$RD not card"; exit 1 ;;
esac

[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS start=$(cat /sys/block/sda/sda16/start 2>/dev/null)"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; big "REFUSE sda16 size"; exit 1; }

mkdir -p /mnt/p3 2>/dev/null
P3=""
for d in /dev/mmcblk0p3 /dev/mmcblk1p3 /dev/mmcblk2p3 ; do
	[ -b "$d" ] || continue
	mount -t btrfs -o ro "$d" /mnt/p3 2>/dev/null && { P3="$d"; break; }
done
U "p3=$P3"
[ -n "$P3" ] || { m "REFUSE cannot mount p3"; big "REFUSE no p3"; exit 1; }
IMG=/mnt/p3/armada-root.img
BYTES=$(stat -c %s "$IMG" 2>/dev/null)
U "image=$IMG bytes=$BYTES"
[ -n "$BYTES" ] || { m "REFUSE no image"; big "REFUSE no image"; exit 1; }

OK=1
# "skipMiB countMiB tag" - skip and count in the order the loop reads them.
for spec in "0 64 head" "7680 64 mid-7.5GiB" "15296 64 tail-15GiB" ; do
	set -- $spec
	IM=$(dd if="$IMG" bs=1M count=$2 skip=$1 2>/dev/null | sha256sum | busybox cut -c1-16)
	DV=$(dd if=/dev/sda16 bs=1M count=$2 skip=$1 2>/dev/null | sha256sum | busybox cut -c1-16)
	M=match
	[ "$IM" = "$DV" ] || { M=DIFFER; OK=0; }
	U "sample $3 skipMiB=$1 countMiB=$2 img=$IM sda16=$DV $M"
	big "sample $3 img=$IM dev=$DV $M up=$(UP)"
done

mkdir -p /mnt/chk 2>/dev/null
MSG=$(mount -t ext4 -o ro /dev/sda16 /mnt/chk 2>&1)
MR=$?
U "mount rc=$MR msg=$MSG"
if [ "$MR" = "0" ] ; then
	U "top=$(ls /mnt/chk 2>/dev/null | busybox tr '\n' ' ')"
	U "osrelease=$(head -c 90 /mnt/chk/usr/lib/os-release 2>/dev/null | busybox tr '\n' ' ')"
	U "init=$(ls -l /mnt/chk/sbin/init 2>/dev/null)"
	U "systemd=$(ls -l /mnt/chk/usr/lib/systemd/systemd 2>/dev/null)"
	U "health=$(ls /mnt/chk/etc/systemd/system/y700-health.service 2>/dev/null) fstab=$(head -c 90 /mnt/chk/etc/fstab 2>/dev/null | busybox tr '\n' ' ')"
	U "du-top:"
	du -sh /mnt/chk/usr /mnt/chk/var 2>/dev/null >> "$OUT"
	F
	umount /mnt/chk 2>/dev/null
else
	OK=0
	m "verify FAILED mount: $MSG"
	big "mount FAILED rc=$MR"
fi

if [ "$OK" != "1" ] ; then
	big "VERIFY FAILED - y700-ufs.txt stays [$(cat "$CARD/y700-ufs.txt" 2>/dev/null)]"
	U "marker left as: $(cat "$CARD/y700-ufs.txt" 2>/dev/null)"
	exit 1
fi

echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt" 2>/dev/null
F
U "marker y700-ufs.txt now: $(cat "$CARD/y700-ufs.txt" 2>/dev/null)"
big "VERIFIED-COMMITTED y700-ufs.txt=UFS_ARMADA_DONE rebooting in 8s up=$(UP)"
sleep 8
reboot 2>/dev/null
m "reboot did not happen"
sleep 300
exit 0