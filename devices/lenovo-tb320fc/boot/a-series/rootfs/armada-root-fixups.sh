#!/bin/sh
# Make the staged UFS root (/mnt/c3/armada-root.img) safe to boot as a *plain*
# ext4 root on the Y700, instead of as the SD card's ostree/btrfs system.
#
# The image is exported from the card's ostree deployment, so /etc still carries
# the card's own mount units: -.mount (mounts the CARD btrfs subvol on /),
# boot.mount and boot-efi.mount (the card's p2/p1 UUIDs), plus an /etc/fstab
# line for /boot on the card. Booted from UFS those either hang local-fs.target
# or try to mount over the real root, so the boot degrades to emergency mode.
# The card partitions must never be auto-mounted from a UFS root.
#
# Also: /mnt/card must exist for y700-health.service, and that service is wanted
# by emergency.target too, so a failed boot still leaves a report on the card.
#
# Run on the OrangePi with the card attached:  sh armada-root-fixups.sh /dev/sdc
set -e
DISK="${1:-/dev/sdc}"
CARD3="$(lsblk -nro NAME,LABEL "$DISK" 2>/dev/null | awk '$2=="root"{print $1; exit}')"
[ -b "$CARD3" ] || { echo "no btrfs LABEL=root on $DISK"; exit 1; }
mkdir -p /mnt/c3 /mnt/img
mountpoint -q /mnt/c3 || mount "$CARD3" /mnt/c3
IMG=/mnt/c3/armada-root.img
[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }
losetup -D 2>/dev/null || true
L=$(losetup -f --show "$IMG")
echo "image loop $L"
mount -o rw "$L" /mnt/img
cd /mnt/img
mkdir -p var/mnt/card var/mnt/p3
for u in -.mount boot.mount boot-efi.mount; do
	rm -f "etc/systemd/system/$u" \
		"etc/systemd/system/multi-user.target.wants/$u" \
		"etc/systemd/system/local-fs.target.wants/$u"
done
cat > etc/fstab <<'FSTAB'
# Y700 TB320FC: ABL loads the kernel from the raw boot_b partition, so there is
# no /boot filesystem here, and the SD card partitions must never be auto-mounted
# from a root that lives on UFS. Mounts come from the initramfs or systemd units.
FSTAB
mkdir -p etc/systemd/system/emergency.target.wants
ln -sf ../y700-health.service etc/systemd/system/emergency.target.wants/y700-health.service
# The image keeps the deployment's /etc, where the dangerous boot writers are
# already masked (bootupd, bootc timer, esp rename via the ostree condition);
# re-assert the two that must never run on a phone-tablet GPT.
ln -sf /dev/null etc/systemd/system/bootloader-update.service
ln -sf /dev/null etc/systemd/system/armada-bootimg-sync.service
sync; sync
cd /
umount /mnt/img
e2fsck -f -y "$L" | tail -6
losetup -d "$L"
echo ARMADA_ROOT_FIXUPS_DONE