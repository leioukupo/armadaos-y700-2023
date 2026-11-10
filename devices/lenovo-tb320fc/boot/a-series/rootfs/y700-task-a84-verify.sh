#!/bin/sh
# A84 verify task: look at UFS sda16 without writing a single byte to it.
#
# Why: A83 wrote all 30 chunks with rc=0, then could not mount sda16 (rc=255), and
# the following UFS-FIRST boot could not switch into it either - so the copy either
# never landed or landed wrong.  The install task hid the reason behind 2>/dev/null,
# so this pass captures everything: blkid, the ext4 superblock bytes, checksums of
# sampled regions of both the staged image and the partition, mount stderr, queue
# geometry, read throughput and any UFS errors in dmesg.
#
# It is read-only by design and never reboots, so the card can be pulled whenever
# the panel says VERIFY-DONE.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A84-VERIFY'
CARD=/mnt/card
OUT=$CARD/y700-a84-verify.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
big() { echo "<6>$K $*" > /dev/kmsg 2>/dev/null; }
UP() { cut -d. -f1 /proc/uptime; }
W() { echo "$*" >> "$OUT" 2>/dev/null; sync; }
U() { echo "up=$(UP) $*" >> "$OUT" 2>/dev/null; sync; }

echo "=== Y700-A84 verify up=$(UP) ===" > "$OUT" 2>/dev/null
big "START read-only verify of /dev/sda16 up=$(UP)"

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
U "rootdev=$RD"
case "$RD" in
	*mmcblk*) : ;;
	*) m "REFUSE root is $RD, not the card"; big "REFUSE root=$RD not card"; exit 1 ;;
esac

[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
if [ ! -b /dev/sda16 ] ; then
	m "no /dev/sda16 at all"
	big "NO sda16 device"
	U "sda present=$(ls /dev/sda* 2>/dev/null | busybox tr '\n' ' ')"
	U "partscan=$(cat /proc/partitions 2>/dev/null | busybox tr '\n' ' ')"
	exit 1
fi

U "size512=$(cat /sys/block/sda/sda16/size 2>/dev/null) want=$WANT_SZS start512=$(cat /sys/block/sda/sda16/start 2>/dev/null)"
U "queue lbs=$(cat /sys/block/sda/queue/logical_block_size 2>/dev/null) pbs=$(cat /sys/block/sda/queue/physical_block_size 2>/dev/null) dalign=$(cat /sys/block/sda/queue/discard_alignment 2>/dev/null)"
U "lsblk:"
lsblk -o NAME,SIZE,TYPE,START /dev/sda >> "$OUT" 2>&1; sync
U "blkid sda16: $(blkid /dev/sda16 2>&1)"
U "blkid sda: $(blkid /dev/sda 2>&1)"
big "blkid: $(blkid /dev/sda16 2>&1)"

# The ext4 superblock lives at byte 1024; its magic 53 ef sits at 0x38 into it.
dd if=/dev/sda16 bs=1024 skip=1 count=1 2>/dev/null | hexdump -C | head -16 >> "$OUT" 2>&1
sync
U "sb-magic=$(dd if=/dev/sda16 bs=1 count=2 skip=1080 2>/dev/null | hexdump -e '1/1 "%02x"')"

mkdir -p /mnt/p3 2>/dev/null
P3=""
for d in /dev/mmcblk0p3 /dev/mmcblk1p3 /dev/mmcblk2p3 ; do
	[ -b "$d" ] || continue
	mount -t btrfs -o ro "$d" /mnt/p3 2>/dev/null && { P3="$d"; break; }
done
U "p3=$P3"
IMG=/mnt/p3/armada-root.img
[ -f "$IMG" ] || { m "no staged image on $P3"; big "NO image to compare"; exit 1; }
IB=$(stat -c %s "$IMG" 2>/dev/null)
U "image=$IMG bytes=$IB"
U "image-sb-magic=$(dd if="$IMG" bs=1 count=2 skip=1080 2>/dev/null | hexdump -e '1/1 "%02x"')"

# Sample three regions rather than hashing 15 GiB over a 7 MB/s SD slot.
for spec in "0 16 head" "8192 4 mid-8GiB" "15352 8 tail-15GiB" ; do
	set -- $spec
	SK=$1; CN=$2; TAG=$3
	DV=$(dd if=/dev/sda16 bs=1M count=$CN skip=$SK 2>/dev/null | sha256sum | busybox cut -c1-16)
	IM=$(dd if="$IMG" bs=1M count=$CN skip=$SK 2>/dev/null | sha256sum | busybox cut -c1-16)
	U "sample $TAG skipMiB=$SK countMiB=$CN sda16=$DV image=$IM match=$([ "$DV" = "$IM" ] && echo YES || echo NO)"
	big "sample $TAG sda16=$DV image=$IM $([ "$DV" = "$IM" ] && echo MATCH || echo DIFFER)"
done

mkdir -p /mnt/chk 2>/dev/null
MT=$(mount -t ext4 -o ro /dev/sda16 /mnt/chk 2>&1)
MR=$?
U "mount-rc=$MR mount-msg=$MT"
big "mount rc=$MR msg=[$MT]"
if [ "$MR" = "0" ] ; then
	U "top=$(ls /mnt/chk 2>/dev/null | busybox tr '\n' ' ')"
	U "osrelease=$(head -c 60 /mnt/chk/usr/lib/os-release 2>/dev/null | busybox tr '\n' ' ')"
	umount /mnt/chk 2>/dev/null
fi

T0=$(cut -d. -f1 /proc/uptime)
dd if=/dev/sda16 bs=1M count=256 of=/dev/null 2>/dev/null
T1=$(cut -d. -f1 /proc/uptime)
U "ufs-read-256MiB-seconds=$((T1 - T0))"
T0=$(cut -d. -f1 /proc/uptime)
dd if="$IMG" bs=1M count=64 of=/dev/null 2>/dev/null
T1=$(cut -d. -f1 /proc/uptime)
U "card-read-64MiB-seconds=$((T1 - T0))"

U "mmc-scan=$(ls /dev/mmcblk* 2>/dev/null | busybox tr '\n' ' ')"
U "dmesg-tail:"
dmesg | busybox tail -40 >> "$OUT" 2>&1
sync
big "VERIFY-DONE see y700-a84-verify.txt up=$(UP)"
m "VERIFY-DONE up=$(UP)"
sleep 90
exit 0