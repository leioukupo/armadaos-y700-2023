#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Make the UFS root image boot straight into an ostree/bootc deployment.
#
# The install flow so far writes a FLAT root to linuxroot and adopts it on the tablet
# afterwards: 1.8 GB base-layer.tar plus 3.5 GB factory-var.tar over Wi-Fi, an ostree
# commit on the device, then two reboots to prove stage-1 composes the root (PROGRESS
# A207-A221). Every one of those steps has cost board time, and the adoption only works
# when the bundle happens to be complete.
#
# Everything the adoption needs already exists at build time, next to the image: the
# registry metadata, the base layer, and the factory state tars that pack-image-state.sh
# now produces. So run the same adoption offline, against the loop-mounted root image,
# and ship an image that already contains
#   /ostree/repo + a deployment of the image + its origin (container-image-reference)
#   /boot/loader/entries/*.conf that stage-1 reads, plus the /ostree/boot.0 symlinks
#   /init + /usr/lib/armada/armada-ostree-{stage1,confirm,bootlink}.sh
#   /etc/armada/ostree-boot = yes (the marker that lets stage-1 compose instead of falling back)
# The first boot then lands on the composed root, with Version/history in Armada tools and
# `bootc status` reporting a booted deployment.
#
# Usage
#   ostree-first-root.sh IMG --image-ref REF --bundle DIR [options]
#   ostree-first-root.sh IMG --image-ref REF --image-meta DIR --base-layer TAR \
#                            [--factory-etc DIR] [--image-var DIR]
#
# Options
#   --bundle DIR        a staged bundle from stage-adopt-bundle.sh: takes imgmeta/,
#                       base-layer.tar and unpacks factory-etc.tar / factory-var.tar
#                       under DIR/state when those tars are present
#   --stateroot NAME    ostree stateroot (default default)
#   --root-karg KARG    kernel argument that pins the root (default root=PARTLABEL=linuxroot)
#   --disarm            write the marker as "no" instead of "yes" (stage-1 installed but
#                       the composed root kept off, for a first bring-up)
#   --dry-run           ask adopt.sh to print what it would commit
#   --mnt DIR           mount point (default /mnt/ufs-ostree-first)
#
# Run on the build machine, as root, against the image build-ufs-root.sh produced (before
# it is pushed to the tablet). The .e2 dump and its sha256 are regenerated afterwards, so
# what gets written to linuxroot is this adopted image.
set -euo pipefail

ROOTFS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ADOPT="$ROOTFS_DIR/armada-ostree-adopt.sh"

IMG=""; BUNDLE=""; IMAGE_REF=""; IMAGE_META=""; BASE_LAYER=""; FACTORY_ETC=""; IMAGE_VAR=""
STATEROOT=default; ROOT_KARG=root=PARTLABEL=linuxroot; MNT=/mnt/ufs-ostree-first
DRY=0; DISARM=0; LABEL=y700root-ufs

log() { echo "ostree-first-root: $*"; }
die() { echo "ostree-first-root: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle)      BUNDLE="${2:?}"; shift 2 ;;
        --bundle=*)    BUNDLE="${1#*=}"; shift ;;
        --image-ref)   IMAGE_REF="${2:?}"; shift 2 ;;
        --image-ref=*) IMAGE_REF="${1#*=}"; shift ;;
        --image-meta)  IMAGE_META="${2:?}"; shift 2 ;;
        --image-meta=*) IMAGE_META="${1#*=}"; shift ;;
        --base-layer)  BASE_LAYER="${2:?}"; shift 2 ;;
        --base-layer=*) BASE_LAYER="${1#*=}"; shift ;;
        --factory-etc) FACTORY_ETC="${2:?}"; shift 2 ;;
        --factory-etc=*) FACTORY_ETC="${1#*=}"; shift ;;
        --image-var)   IMAGE_VAR="${2:?}"; shift 2 ;;
        --image-var=*) IMAGE_VAR="${1#*=}"; shift ;;
        --stateroot)   STATEROOT="${2:?}"; shift 2 ;;
        --root-karg)   ROOT_KARG="${2:?}"; shift 2 ;;
        --mnt)         MNT="${2:?}"; shift 2 ;;
        --label)       LABEL="${2:?}"; shift 2 ;;
        --disarm)      DISARM=1; shift ;;
        --dry-run)     DRY=1; shift ;;
        -h|--help)     sed -n '3,44p' "$0"; exit 0 ;;
        -*)            die "unknown option $1" ;;
        *)             [[ -z "$IMG" ]] || die "only one image at a time"; IMG="$1"; shift ;;
    esac
done

[[ -n "$IMG" ]] || die "usage: $(basename "$0") IMG --image-ref REF --bundle DIR"
[[ -f "$IMG" ]] || die "no such image: $IMG"
[[ -n "$IMAGE_REF" ]] || die "--image-ref is required (it is what makes the origin bootc-managed)"

if [[ -n "$BUNDLE" ]]; then
    IMAGE_META=${IMAGE_META:-$BUNDLE/imgmeta}
    BASE_LAYER=${BASE_LAYER:-$BUNDLE/base-layer.tar}
    if [[ -z "$FACTORY_ETC" && -f "$BUNDLE/factory-etc.tar" ]]; then
        mkdir -p "$BUNDLE/state"
        tar -xf "$BUNDLE/factory-etc.tar" -C "$BUNDLE/state"
        FACTORY_ETC="$BUNDLE/state/etc"
    fi
    if [[ -z "$IMAGE_VAR" && -f "$BUNDLE/factory-var.tar" ]]; then
        mkdir -p "$BUNDLE/state"
        tar -xf "$BUNDLE/factory-var.tar" -C "$BUNDLE/state"
        IMAGE_VAR="$BUNDLE/state/var"
    fi
fi
[[ -f "$IMAGE_META/manifest.json" && -f "$IMAGE_META/config.json" ]] ||
    die "no $IMAGE_META/{manifest,config}.json - stage the bundle first (stage-adopt-bundle.sh)"
[[ -f "$BASE_LAYER" ]] || die "no base layer: $BASE_LAYER"
[[ -x "$ADOPT" ]] || die "no executable adopt script at $ADOPT"

for tool in ostree mount umount blkid; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
[[ "$(id -u)" == 0 ]] || die "run as root: it loop-mounts $IMG"

IMG_ABS=$(realpath "$IMG")
if mount | grep -qF " $IMG_ABS "; then
    die "$IMG is already mounted - unmount it first so the checks below see the final bytes"
fi
mkdir -p "$MNT"
mountpoint -q "$MNT" && die "$MNT is already a mount point - choose --mnt"
mount -o loop "$IMG_ABS" "$MNT" || die "cannot loop-mount $IMG_ABS"
cleanup() { mountpoint -q "$MNT" 2>/dev/null && umount "$MNT"; return 0; }
trap cleanup EXIT

# The tree has to be the flat root build-ufs-root.sh writes, with the stage-1 runtime
# already baked into it. Without those files the adoption commits a deployment that cannot
# be composed at boot, and the failure only shows up on the tablet.
[[ -f "$MNT/usr/lib/os-release" ]] || die "$IMG has no /usr/lib/os-release - is this a root image?"
[[ -f "$MNT/etc/passwd" ]] || die "$IMG has no /etc/passwd - this is not a root filesystem"
[[ -x "$MNT/usr/lib/armada/armada-ostree-stage1.sh" ]] ||
    die "$IMG was built without the stage-1 runtime in it; build it with build-ufs-root.sh"
if [[ -d "$MNT/ostree/repo" ]]; then
    die "$IMG already has /ostree/repo - adopting twice is not supported, rebuild the flat root"
fi
# libostree insists that <sysroot>/boot/loader is a symlink (it writes loader.0/loader.1
# and points loader at the newest, which is why stage-1 reads /boot/loader.N/entries).
# A real directory there makes "ostree admin deploy" fail with "Not a symbolic link:
# boot/loader", so move it aside and say so instead of failing inside ostree.
if [[ -e "$MNT/boot/loader" && ! -L "$MNT/boot/loader" ]]; then
    entries=$(find "$MNT/boot/loader/entries" -name '*.conf' 2>/dev/null | wc -l)
    if [[ "$entries" != 0 ]]; then
        die "$MNT/boot/loader holds $entries BLS entries as a real directory - stage-1 would"
    fi
    mv "$MNT/boot/loader" "$MNT/boot/loader.pre-adopt"
    log "moved the empty $MNT/boot/loader aside; libostree needs boot/loader to be a symlink"
fi
log "flat root: $(blkid -o value -s LABEL "$IMG_ABS" 2>/dev/null) $(blkid -o value -s UUID "$IMG_ABS" 2>/dev/null)"
[[ -n "$IMAGE_VAR" ]] && log "image /var: $IMAGE_VAR ($(find "$IMAGE_VAR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) top-level)"
[[ -n "$FACTORY_ETC" ]] && log "image /etc: $FACTORY_ETC ($(find "$FACTORY_ETC" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) top-level)"
[[ -z "$IMAGE_VAR" ]] && log "warning: no image /var - the commit gets an empty /var skeleton and Steam repair will have nothing to export"

ARGS=(--sysroot "$MNT" --from flat --stage1 install --stateroot "$STATEROOT"
      --root-karg "$ROOT_KARG" --image-ref "$IMAGE_REF"
      --image-meta "$IMAGE_META" --base-layer "$BASE_LAYER")
[[ -n "$FACTORY_ETC" ]] && ARGS+=(--factory-etc "$FACTORY_ETC")
[[ -n "$IMAGE_VAR" ]] && ARGS+=(--image-var "$IMAGE_VAR")
[[ "$DISARM" == 0 ]] && ARGS+=(--enable-stage1)
[[ "$DRY" == 1 ]] && ARGS+=(--dry-run)

log "adopting offline"
"$ADOPT" "${ARGS[@]}" 2>&1 | tee "${IMG_ABS}.adopt.log"
if [[ "$DRY" == 1 ]]; then
    log "dry run only - nothing changed"
    exit 0
fi

# ---- what has to be true before this image goes to the tablet -----------------
fail=0
note() { if eval "$2"; then log "ok:   $1"; else log "FAIL: $1"; fail=$((fail + 1)); fi; }

status=$(ostree admin --sysroot="$MNT" status 2>&1)
note "ostree admin status lists a deployment" "grep -q 'Deployment' <<<\"\$status\""
note "the origin is the container reference" \
     "grep -q 'container-image-reference' \"$MNT\"/ostree/deploy/$STATEROOT/deploy/*.origin"
note "/init is the stage-1 launcher" "[[ -x $MNT/init ]]"
note "stage-1 runtime is on the physical root" "[[ -x $MNT/usr/lib/armada/armada-ostree-stage1.sh ]]"
note "confirm unit is wanted by basic.target" \
     "ls \"$MNT\"/ostree/deploy/$STATEROOT/deploy/*/etc/systemd/system/basic.target.wants/armada-ostree-confirm.service >/dev/null 2>&1"
marker=$(tr -d ' \t\r\n' < "$MNT/etc/armada/ostree-boot" 2>/dev/null)
want=yes; [[ "$DISARM" == 1 ]] && want=no
note "marker /etc/armada/ostree-boot is [$want]" "[[ \$marker == $want ]]"

bls=( "$MNT"/boot/loader*/entries/ostree-*.conf )
[[ -e "${bls[0]}" ]] || die "no BLS entries under $MNT/boot/loader*/entries - stage-1 has nothing to boot"
[[ -L "$MNT/boot/loader" ]] || log "note: $MNT/boot/loader is not a symlink; stage-1 globs boot/loader.N"
for f in "${bls[@]}"; do
    opts=$(sed -n 's/^options //p' "$f" | head -1)
    log "BLS $(basename "$f"): options ${#opts} B"
    (( ${#opts} <= 512 )) || { log "FAIL: ABL takes at most 512 B of cmdline"; fail=$((fail + 1)); }
    [[ "$opts" == *"$ROOT_KARG"* ]] || { log "FAIL: $ROOT_KARG missing from $(basename "$f")"; fail=$((fail + 1)); }
done
note "stage-1 can resolve the boot links" \
     "find \"$MNT/ostree/boot.0/$STATEROOT\" -maxdepth 1 -type l | grep -q ."

umount "$MNT"
trap - EXIT
e2fsck -f -y "$IMG_ABS" > /dev/null || die "e2fsck after the adoption failed"
tune2fs -L "$LABEL" "$IMG_ABS" > /dev/null || log "warning: could not re-apply label $LABEL"

# The install pushes the e2image restore file, not the 345 GB sparse image: metadata plus
# allocated blocks only (PROGRESS A204, and build-ufs-root.sh's closing comment).
if command -v e2image >/dev/null; then
    rm -f "${IMG_ABS}.e2"
    e2image -r "$IMG_ABS" "${IMG_ABS}.e2"
    sha256sum "$IMG_ABS" "${IMG_ABS}.e2" | tee "${IMG_ABS}.sha256"
    log "dump: $(du -h "${IMG_ABS}.e2" | cut -f1)"
else
    log "warning: no e2image - write $IMG_ABS to linuxroot yourself"
fi
log "adopt log: ${IMG_ABS}.adopt.log"
df -h "$IMG_ABS" 2>/dev/null | tail -1 | sed 's/^/  /' || true
dumpe2fs -h "$IMG_ABS" 2>/dev/null | awk '/Block count|Free blocks/{print "  " $0}' || true

if (( fail )); then
    die "$fail post-adoption checks failed - do not push this image (log: ${IMG_ABS}.adopt.log)"
fi
echo "OSTREE_FIRST_OK $IMG_ABS"