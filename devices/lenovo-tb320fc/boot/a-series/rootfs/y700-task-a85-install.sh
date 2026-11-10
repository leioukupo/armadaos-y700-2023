#!/bin/sh
# A85 install task: copy the staged ArmadaOS root (armada-root.img on the card's
# btrfs p3) onto UFS partition 16 (linuxroot), then only announce success if the
# partition actually reads back as the image.
#
# A83's fatal bug: every chunk was written with `skip=$OFF` (input offset) but no
# `seek=$OFF` (output offset), so all 30 chunks landed on the first 512 MiB of
# sda16, each overwriting the previous one.  dd returned rc=0 the whole way, which
# is why "all chunks rc=0" proved nothing.  A84 (read-only verify) exists in this
# directory for confirming that kind of thing without touching the disk.
#
# A85 therefore:
#   * dd with skip AND seek (chunk index * CH_MIB, in bs=1M units);
#   * iflag=fullblock so a short read is an error instead of a silent hole;
#   * read back a sample after every chunk, so a bad chunk is named on the panel;
#   * verify three sampled regions plus a real ext4 mount BEFORE writing
#     UFS_ARMADA_DONE; a failed verify leaves the marker alone and does not reboot.
# Gates before any byte is written: root must be the SD card, y700-install.txt must
# say INSTALL_ARMADA_GO, and sda16 must be the 675529368-sector partition the A40
# surgery created.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A85-INSTALL'
CARD=/mnt/card
S=$CARD/y700-a85-step.txt
SUM=$CARD/y700-a85-summary.txt
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
echo "=== Y700-A85 install up=$(UP) ===" > "$SUM" 2>/dev/null
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
sum "sda16 sectors=$SZS want=$WANT_SZS start=$(cat /sys/block/sda/sda16/start 2>/dev/null)"
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
BYTES=$(stat -c %s "$IMG" 2>/dev/null)
[ -n "$BYTES" ] || BYTES=$(busybox stat -c %s "$IMG" 2>/dev/null)
BYTES=${BYTES:-0}
sum "image=$IMG bytes=$BYTES"
if [ "$BYTES" -lt 4294967296 ] ; then
	m "REFUSE image too small ($BYTES)"
	big "REFUSE image too small"
	step exit
	exit 1
fi
m "image present: $BYTES bytes on $P3"

# Does O_DIRECT work on this UFS LUN at all?  Chunk 0 rewrites whatever this
# probe touches, so writing 1 MiB of zeros here is harmless and tells us why a
# dd had to fall back to buffered writes.
PROBE=$(dd if=/dev/zero of=/dev/sda16 bs=1M count=1 seek=0 oflag=direct conv=notrunc 2>&1)
sum "odirect-probe rc=$? msg=$(echo "$PROBE" | busybox tr '\n' ' ')"

CH_BYTES=$((CH_MIB * 1048576))
NCH=$(( (BYTES + CH_BYTES - 1) / CH_BYTES ))
big "dd $BYTES bytes -> /dev/sda16 ($NCH chunks of $CH_MIB MiB, skip+seek)"
step dd-start
i=0
RC=0
while [ $i -lt $NCH ] ; do
	OFF=$(( i * CH_MIB ))
	dd if="$IMG" of=/dev/sda16 bs=1M count=$CH_MIB iflag=fullblock skip=$OFF oflag=direct seek=$OFF conv=notrunc 2>/dev/null
	RC=$?
	if [ "$RC" != "0" ] ; then
		sum "chunk $i direct rc=$RC - retrying buffered"
		dd if="$IMG" of=/dev/sda16 bs=1M count=$CH_MIB iflag=fullblock skip=$OFF seek=$OFF conv=notrunc 2>/dev/null
		RC=$?
	fi
	[ "$RC" = "0" ] || break
	F
	# read back the tail of the chunk we just wrote; a wrong seek shows up here
	# immediately instead of after 15 GiB
	TAIL=$(( OFF + CH_MIB - 1 ))
	IMSH=$(dd if="$IMG" bs=1M count=1 skip=$TAIL 2>/dev/null | sha256sum | busybox cut -c1-12)
	DVSH=$(dd if=/dev/sda16 bs=1M count=1 skip=$TAIL 2>/dev/null | sha256sum | busybox cut -c1-12)
	MTAG=match
	[ "$IMSH" = "$DVSH" ] || MTAG=MISMATCH
	i=$((i + 1))
	sum "chunk $i/$NCH rc=$RC tail-sha img=$IMSH sda16=$DVSH $MTAG up=$(UP)"
	m "dd $i/$NCH $MTAG up=$(UP)"
	big "dd $i/$NCH ($(( i * 100 / NCH ))%) $MTAG img=$IMSH dev=$DVSH up=$(UP)"
	[ "$MTAG" = "match" ] || { RC=9; break; }
done
step dd-done
if [ "$RC" != "0" ] ; then
	m "dd FAILED rc=$RC at chunk $i"
	big "dd FAILED rc=$RC at chunk $i - leaving y700-ufs.txt alone"
	sum "dd rc=$RC at chunk $i"
	step verify-failed
	exit 1
fi
F
big "dd finished $NCH chunks, verifying"

OK=1
for spec in "0 16 head" "8192 4 mid-8GiB" "15352 8 tail-15GiB" ; do
	set -- $spec
	IM=$(dd if="$IMG" bs=1M count=$1 skip=$2 2>/dev/null | sha256sum | busybox cut -c1-16)
	DV=$(dd if=/dev/sda16 bs=1M count=$1 skip=$2 2>/dev/null | sha256sum | busybox cut -c1-16)
	[ "$IM" = "$DV" ] || OK=0
	sum "sample $3 skip=$2 count=$1 img=$IM sda16=$DV"
	big "sample $3 img=$IM dev=$DV $([ "$IM" = "$DV" ] && echo MATCH || echo DIFFER)"
done

mkdir -p /mnt/chk 2>/dev/null
MSG=$(mount -t ext4 -o ro /dev/sda16 /mnt/chk 2>&1)
MR=$?
sum "verify mount rc=$MR msg=$MSG"
if [ "$MR" = "0" ] ; then
	sum "top=$(ls /mnt/chk 2>/dev/null | busybox tr '\n' ' ')"
	sum "osrelease=$(head -c 80 /mnt/chk/usr/lib/os-release 2>/dev/null | busybox tr '\n' ' ')"
	sum "init=$(ls -l /mnt/chk/sbin/init 2>/dev/null) systemd=$(ls -l /mnt/chk/usr/lib/systemd/systemd 2>/dev/null)"
	sum "health-unit=$(ls /mnt/chk/etc/systemd/system/y700-health.service 2>/dev/null)"
	umount /mnt/chk 2>/dev/null
else
	OK=0
	m "verify FAILED cannot mount sda16: $MSG"
	big "verify FAILED mount rc=$MR"
fi

if [ "$OK" != "1" ] ; then
	big "VERIFY FAILED - y700-ufs.txt left as $(cat "$CARD/y700-ufs.txt" 2>/dev/null), not rebooting"
	step verify-failed
	exit 1
fi

# Verified: hand the next boot to the UFS root.
echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt" 2>/dev/null
F
sum "marker y700-ufs.txt now: $(cat "$CARD/y700-ufs.txt" 2>/dev/null)"
m "DONE chunks=$NCH up=$(UP)"
step exit
big "INSTALL VERIFIED - rebooting in 8s"
sleep 8
reboot 2>/dev/null
m "reboot did not happen, holding"
sleep 300