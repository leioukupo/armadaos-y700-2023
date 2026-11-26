#!/bin/bash
# Write a boot slot from inside a running system on the tablet (root).
#
#   flash_slot.sh <a|b> <image> <expected-image-sha256> [expected-current-sha256]
#
# No fastboot needed: while any OS runs, boot_a / boot_b are unmounted block
# devices (the kernel image is already in RAM). The rules baked in here are the
# ones every round followed:
#   * resolve the device, never trust a disk letter (sde13 became sdd13 between
#     two boots);
#   * refuse a mounted partition;
#   * verify the source sha before writing, dump the current partition to the
#     rollback directory, and read the whole partition back afterwards;
#   * never touch misc, never change the active slot: this board stores the slot
#     in XBL's own NV and `fastboot --set-active` is the only writer.
set -uo pipefail

SLOT="${1:?usage: flash_slot.sh <a|b> <image> <expected-image-sha256> [expected-current-sha256]}"
IMG="${2:?packed boot image}"
WANT="${3:?expected sha256 of the image}"
PRE="${4:-}"
ROLLBACK=${ROLLBACK:-/root/kshim-rollback}
TAG=${TAG:-manual}

[ -f "$IMG" ] || { echo "no image at $IMG" >&2; exit 1; }
mkdir -p "$ROLLBACK"

P=$(readlink -f "/dev/disk/by-partlabel/boot_$SLOT")
[ -n "$P" ] && [ -e "$P" ] || { echo "cannot resolve boot_$SLOT" >&2; exit 1; }
echo "slot $SLOT -> $P"
if mount | grep -q "^$P "; then echo "REFUSE: $P is mounted" >&2; exit 1; fi

got=$(sha256sum "$IMG" | cut -d' ' -f1)
[ "$got" = "$WANT" ] || { echo "SOURCE_SHA_FAIL got=$got want=$WANT" >&2; exit 1; }

cur=$(sha256sum "$P" | cut -d' ' -f1)
echo "current partition sha256=$cur"
if [ -n "$PRE" ] && [ "$cur" != "$PRE" ]; then
  echo "PRE_SHA_MISMATCH: expected $PRE, the board is not in the state this flash was planned for" >&2
  exit 1
fi

BK="$ROLLBACK/boot_${SLOT}-pre-$TAG.img"
dd if="$P" of="$BK" bs=4M status=none
echo "rollback copy: $BK ($(stat -c %s "$BK") bytes, $(sha256sum "$BK" | cut -c1-16)…)"

dd if="$IMG" of="$P" bs=4M conv=fsync status=none
sync
blockdev --flushbufs "$P" 2>/dev/null || true

back=$(sha256sum "$P" | cut -d' ' -f1)
if [ "$back" = "$WANT" ]; then
  echo "FLASH_${SLOT}_OK $back"
else
  echo "FLASH_${SLOT}_MISMATCH got=$back want=$WANT" >&2
  echo "recover with: dd if=$BK of=$P bs=4M conv=fsync" >&2
  exit 1
fi
