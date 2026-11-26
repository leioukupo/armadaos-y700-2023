#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Grow the flashed root filesystem to the size of the linuxroot partition, on the tablet.
#
# Why this exists: ext4 keeps an inode table at the start of every flex group, so a 322 GiB
# root carries bytes all the way out to its last block group even when it only holds 14 GiB.
# Firehose has no notion of a hole - edl.py streams os.stat(file).st_size bytes - so flashing
# such an image is hours of zeros. The build shrinks the filesystem to what it holds
# (ostree-first-root.sh) and this unit grows it back once, on the first boot.
#
# Grow is the only resize the kernel allows online, so / does not have to be unmounted and
# there is no second reboot. The unit is gated on a marker file that only a shrunk image
# ships; once the grow succeeds the marker is removed and the unit stays inert forever.
set -uo pipefail

MARKER=/etc/armada/need-growfs
root=$(findmnt -n -o SOURCE / 2>/dev/null)
if [[ -z "$root" || ! -b "$root" ]]; then
    echo "armada-growfs: cannot resolve the root block device (got '$root')" >&2
    exit 1
fi

before=$(blockdev --getsize64 "$root")
# resize2fs with no size grows the filesystem to the device, and says "nothing to do" when
# it already fills it - so re-running this on a board that was already grown costs nothing.
if ! resize2fs "$root" >&2; then
    echo "armada-growfs: resize2fs $root failed; leaving the filesystem as it is" >&2
    exit 1
fi
after=$(findmnt -n -o SIZE / 2>/dev/null)
rm -f "$MARKER"
echo "armada-growfs: $root device is $before bytes, filesystem is now $after"