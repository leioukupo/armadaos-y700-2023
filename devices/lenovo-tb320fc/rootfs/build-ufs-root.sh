#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the UFS linuxroot image for the Y700 Gen 2 (TB320FC).
#
#   source  : a podman image built from this repo (the tree carries every
#             tb320fc-* unit, helper, UCM/tplg and firmware file), extracted
#             with podman image mount -- no cross-arch execution needed.
#   output  : ONE ext4 filesystem whose geometry is exactly the linuxroot
#             partition (345,871,036,416 B), label y700root-ufs, holding the
#             tree as a flat root.  The A-series initramfs in boot_a does
#             "findfs LABEL=y700root-ufs" and switch_roots into it, so the
#             geometry match is what lets us restore the e2image dump straight
#             onto the partition with no resize step on the board.
#
# Board-specific state that the image cannot carry (no /boot filesystem, the
# payload kernel version differs from the image kernel, autologin, sleep
# policy) is written here, the same way the Nov 14 build did it.
#
# Usage: build-ufs-root.sh [IMAGE] [OUTDIR]
set -euo pipefail

IMAGE="${1:-localhost/armada:20261125.2a22d22}"
OUTDIR="${2:-/srv/y700/a206}"

# linuxroot = LUN0 LBAs 36827048..121268218 with 4096-byte logical blocks.
PART_BYTES=345871036416
KVER=7.3.0-rc6
LABEL=y700root-ufs

# The payload kernel module tree, and the patched copies that must win over the
# mainline ones (tb320fc-modules-tree moves them into extra/ and prunes the
# shadowed kernel/ copies; STAGE_DIRS is what that helper scans).
MODS_SRC="${MODS_SRC:-/srv/y700/stage-73mods/lib/modules/$KVER}"
KO_PATCHED_SRC="${KO_PATCHED_SRC:-/srv/y700/g4/a211/initramfs/y700-ko}"

OUT="$OUTDIR/root-$(printf '%s' "$IMAGE" | sed 's#.*/##; s#: #-#').img"
DUMP="$OUT.e2"
MNT=/mnt/newroot
SRC=

log() { echo "build-ufs-root: $*"; }
cleanup() {
    if [ -n "$SRC" ]; then podman image unmount "$IMAGE" >/dev/null 2>&1 || true; fi
    mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" || true
}
trap cleanup EXIT

[ -f "$MODS_SRC/modules.dep" ] || { echo "no module tree: $MODS_SRC" >&2; exit 1; }
[ -d "$KO_PATCHED_SRC" ] || { echo "no patched .ko dir: $KO_PATCHED_SRC" >&2; exit 1; }
mkdir -p "$OUTDIR" "$MNT"

SRC=$(podman image mount "$IMAGE") || { echo "cannot mount $IMAGE" >&2; exit 1; }
log "image tree: $SRC"

rm -f "$OUT"
truncate -s "$PART_BYTES" "$OUT"
# -N keeps the inode table to 512 MiB instead of mkfs default 5.4 GiB for this
# size; an ArmadaOS root needs well under 2 million inodes and the dump file
# carries every inode table byte.
mkfs.ext4 -q -F -m 0 -L "$LABEL" -N 2000000 \
    -E lazy_itable_init=0,lazy_journal_init=0 "$OUT"
mount -o loop "$OUT" "$MNT"

log "copying the image tree"
cp -a "$SRC"/. "$MNT"/
rm -f "$MNT/.ostree.cfs"

# --- no /boot filesystem: ABL loads the kernel from the raw boot_a/boot_b
# --- partition, so nothing may be auto-mounted from a root that lives on UFS.
cat > "$MNT/etc/fstab" <<'FSTAB'
# Y700 TB320FC: ABL loads the kernel from the raw boot_a/boot_b partition, so
# there is no /boot filesystem here and SD-card partitions must never be
# auto-mounted from a root that lives on UFS.  Mounts come from the initramfs
# or from systemd units.
FSTAB

# --- Plasma Mobile autologin.  The image ships gamescope/steam as the default
# --- session; sddm reads /etc/sddm.conf.d in order, so this wins over
# --- armada.conf and steam stays a switchable session (armada-session-default).
mkdir -p "$MNT/etc/sddm.conf.d"
cat > "$MNT/etc/sddm.conf.d/zz-y700-autologin.conf" <<'SDDM'
[Autologin]
User=armada
Session=armada-plasma-mobile.desktop
Relogin=true
SDDM

# --- Refuse suspend: s2idle kills the ADSP, and with it the PMIC GLINK battery
# --- gauge, AudioReach and Wi-Fi (A147).
mkdir -p "$MNT/etc/systemd/sleep.conf.d"
cat > "$MNT/etc/systemd/sleep.conf.d/10-y700-no-suspend.conf" <<'SLEEP'
# s2idle kills the ADSP: the PMIC GLINK battery gauge, AudioReach and Wi-Fi all
# live on it, so one suspend/resume cycle leaves the battery reading empty and
# the desktop believes the cell is flat.  Suspend is therefore refused.
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
SLEEP

# --- A stable machine-id: the image leaves it empty, and every empty-machine-id
# --- boot generates a new one, which is one more source of churn next to the
# --- ath11k MAC drift that tb320fc-wifi-mac already pins down.
MID=$(printf 'tb320fc:machine-id' | sha256sum | cut -c1-32)
printf '%s\n' "$MID" > "$MNT/etc/machine-id"
printf '%s\n' "$MID" > "$MNT/var/lib/dbus/machine-id" 2>/dev/null || true

# --- Payload kernel modules.  The image carries /usr/lib/modules/7.2.6-tb320fc,
# --- but the boot payload that actually runs on Gen 2 is 7.3.0-rc6, and
# --- tb320fc-modules-tree binds /var/usrlocal/lib/y700-73mods/$(uname -r) onto
# --- /usr/lib/modules/$(uname -r).  /var is the stateroot var that every
# --- deployment shares, so the tree survives an update; the patched copies go
# --- to /usr/lib/y700 because that is a STAGE_DIRS entry of the same helper.
mkdir -p "$MNT/var/usrlocal/lib/y700-73mods/$KVER"
cp -a "$MODS_SRC"/. "$MNT/var/usrlocal/lib/y700-73mods/$KVER"/
mkdir -p "$MNT/usr/lib/y700"
cp -a "$KO_PATCHED_SRC"/. "$MNT/usr/lib/y700"/

# --- Units that assume another device's boot chain (ESP /KERNEL, bootupd,
# --- ostree-native /boot, gamepad/deck hardware this board does not have).
MASKS="
proc-sys-fs-binfmt_misc.mount
usr-share-guestos-android.mount
var-lib-nfs-rpc_pipefs.mount
armada-rgb-brightness-watch.path
armada-steam-oobe.path
lvm-devices-import.path
armada-als-bridge.service
armada-boot-hotkeys.service
armada-bootimg-sync.service
armada-control.service
armada-controller-type.service
armada-decky-sync.service
armada-device-quirks.service
armada-esp-rename.service
armada-fixups.service
armada-flatpak-setup.service
armada-g9-double-home.service
armada-guestos.service
armada-input-calibration.service
armada-installer-visibility.service
armada-mtp.service
armada-powerd.service
armada-rgb-brightness-watch.service
armada-rgb.service
armada-save-devcoredump@.service
armada-session-default.service
armada-splash-early.service
armada-splash-poweroff-screen.service
armada-splash-reboot-screen.service
armada-steam-oobe.service
armada-steamapps.service
armada-update-reserve.service
armada-waydroid-input.service
bootc-generic-growpart.service
bootloader-update.service
flatpak-add-fedora-repos.service
inputplumber.service
irqbalance.service
lvm-devices-import.service
lvm2-monitor.service
mdmonitor.service
plugin_loader.service
sssd.service
steamos-manager.service
systemd-backlight@.service
systemd-binfmt.service
systemd-hibernate.service
systemd-hybrid-sleep.service
systemd-suspend-then-hibernate.service
systemd-suspend.service
lvm2-lvmpolld.socket
bootc-fetch-apply-updates.timer
"
for u in $MASKS; do
    mkdir -p "$MNT/etc/systemd/system/$(dirname "$u")"
    rm -f "$MNT/etc/systemd/system/$u"
    ln -s /dev/null "$MNT/etc/systemd/system/$u"
done

# --- Board bring-up units must be wanted even if the image preset missed one.
want() {
    mkdir -p "$MNT/etc/systemd/system/$2.wants"
    ln -sf "/usr/lib/systemd/system/$1.service" "$MNT/etc/systemd/system/$2.wants/$1.service"
}
for u in tb320fc-audio tb320fc-power tb320fc-touch tb320fc-wifi tb320fc-wifi-mac \
         tb320fc-input tb320fc-legacy-off; do
    want "$u" multi-user.target
done
for u in tb320fc-modules-tree tb320fc-usr-overlay; do
    want "$u" sysinit.target
done

# --- Repo-carried fixes the pinned base image does not have yet.  The podman tree
# --- this build starts from comes from an older commit, so a helper added in the
# --- working tree would otherwise exist only in the image build and the flat root
# --- would silently ship without it.  SYSFILES points elsewhere when the bake runs
# --- from a staging dir instead of a checkout.
SYSFILES="${SYSFILES:-$(cd "$(dirname "$0")/../../.." && pwd)/system_files}"
while read -r f mode; do
    [ -n "$f" ] || continue
    [ -f "$SYSFILES/$f" ] || { echo "no $f under SYSFILES=$SYSFILES" >&2; exit 1; }
    mkdir -p "$MNT/$(dirname "$f")"
    install -m "$mode" "$SYSFILES/$f" "$MNT/$f"
    log "baked $f"
done <<'BAKED'
usr/libexec/tb320fc/misc-clear 0755
usr/lib/systemd/system/tb320fc-misc-clear.service 0644
etc/tb320fc/misc-clear.conf 0644
BAKED
want tb320fc-misc-clear shutdown.target
# --- bootc must not try to rebuild a boot image when a deployment finalizes.
# --- ABL loads kernel/DTB/initramfs from the raw boot_a partition and this board has
# --- no ESP /KERNEL, so /etc/armada/boot-method has to say none: without the file
# --- armada-bootimg-finalize defaults to abl, its update step fails, and the failure
# --- branch runs `bootc rollback` - which silently undoes the staged deployment we
# --- are about to create (PROGRESS A197 on the installed board, A207 here).
mkdir -p "$MNT/etc/armada"
printf 'none\n' > "$MNT/etc/armada/boot-method"
chmod 0644 "$MNT/etc/armada/boot-method"
# --- Firmware layout insurance: /usr/libexec/tb320fc/audio checks
# --- /usr/lib/firmware/cirrus, the CS35L45 loader asks for cirrus/..., and the
# --- 7.3.0-rc6 (asphalt) Novatek driver asks for novatek/lenovo-tb320fc.bin.
mkdir -p "$MNT/usr/lib/firmware/cirrus" "$MNT/usr/lib/firmware/novatek"
for f in spk1-cs35l45-dsp1-spk-prot.bin spk1-cs35l45-dsp1-spk-prot.wmfw \
         spk2-cs35l45-dsp1-spk-prot.bin spk2-cs35l45-dsp1-spk-prot.wmfw; do
    [ -f "$MNT/usr/lib/firmware/$f" ] && ln -sf "../$f" "$MNT/usr/lib/firmware/cirrus/$f"
done
for src in novatek_ts_fw.bin novatek_ts_csot_3k_fw.bin; do
    if [ -f "$MNT/usr/lib/firmware/$src" ]; then
        cp -f "$MNT/usr/lib/firmware/$src" "$MNT/usr/lib/firmware/novatek/lenovo-tb320fc.bin"
        break
    fi
done
chmod 0644 "$MNT/usr/lib/firmware/novatek/lenovo-tb320fc.bin" 2>/dev/null || true

# --- Sanity: the autologin user has to exist, with a home under /var/home.
grep -q '^armada:' "$MNT/etc/passwd" || { echo "image has no armada user" >&2; exit 1; }
install -d -m 0750 -o "$(stat -c %u "$MNT/etc/passwd" >/dev/null; id -u armada 2>/dev/null || echo 1000)" \
    "$MNT/var/home/armada" 2>/dev/null || mkdir -p "$MNT/var/home/armada"

sync
umount "$MNT"
e2fsck -f -y "$OUT" >/dev/null
tune2fs -L "$LABEL" "$OUT" >/dev/null
log "image: $(du -h "$OUT" | cut -f1) allocated of $PART_BYTES bytes"

# --- Restore file: metadata plus allocated blocks only, which is what gets
# --- pushed over adb and written back with the aarch64 e2image on the board.
e2image -r "$OUT" "$DUMP"
log "dump: $(du -h "$DUMP" | cut -f1)"
sha256sum "$OUT" "$DUMP" | tee "$OUT.sha256"
echo "ROOT-BUILD-DONE $DUMP"
