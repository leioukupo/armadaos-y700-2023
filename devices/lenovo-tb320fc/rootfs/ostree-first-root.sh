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
#   /boot/loader.N/entries/*.conf that stage-1 reads, plus the matching /ostree/boot.N links
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
#   --check-only        skip the adoption and run only the post-adoption gates, against an
#                       image that already carries /ostree/repo (cheap re-verification)
#   --no-shrink         keep the filesystem at the full partition size. Only do that when the
#                       image will not go over firehose: the used blocks are scattered out to
#                       the last block group, so flashing an unshrunk root means 322 GiB.
#   --dry-run           ask adopt.sh to print what it would commit
#   --mnt DIR           mount point (default /mnt/ufs-ostree-first)
#
# The last step makes the image flashable: the filesystem is shrunk to what it holds
# (+ SHRINK_MARGIN GiB) and the tablet grows it back to the partition on its first boot
# (armada-growfs.service, armed by /etc/armada/need-growfs). Firehose streams bytes, not
# extents, so without the shrink the install pushes hundreds of GiB of holes.
#
# Run on the build machine, as root, against the image build-ufs-root.sh produced.
set -euo pipefail

ROOTFS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ADOPT="$ROOTFS_DIR/armada-ostree-adopt.sh"

# Named patterns for the post-adoption gates, so tests/ostree-first-root-test.sh can run
# the same matching against captured real output instead of a copy that can drift.
STATUS_RE_TPL='^[[:space:]]+@STATEROOT@ [0-9a-f]+\.0'
FARM_GLOB_TPL='ostree/boot.@BOOTV@*/@STATEROOT@'

IMG=""; BUNDLE=""; IMAGE_REF=""; IMAGE_META=""; BASE_LAYER=""; FACTORY_ETC=""; IMAGE_VAR=""
STATEROOT=default; ROOT_KARG=root=PARTLABEL=linuxroot; MNT=/mnt/ufs-ostree-first
DRY=0; DISARM=0; CHECK=0; NOSHRINK=0; LABEL=y700root-ufs
# Free space left in the flashed image, in GiB: room for /var writes during the boot that
# runs armada-growfs.sh, including the boot where that grow might fail.
SHRINK_MARGIN=${SHRINK_MARGIN:-8}

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
        --check-only)  CHECK=1; shift ;;
        --no-shrink)   NOSHRINK=1; shift ;;
        -h|--help)     sed -n '3,59p' "$0"; exit 0 ;;
        -*)            die "unknown option $1" ;;
        *)             [[ -z "$IMG" ]] || die "only one image at a time"; IMG="$1"; shift ;;
    esac
done

[[ -n "$IMG" ]] || die "usage: $(basename "$0") IMG --image-ref REF --bundle DIR"
[[ -f "$IMG" ]] || die "no such image: $IMG"
[[ "$CHECK" == 1 || -n "$IMAGE_REF" ]] || die "--image-ref is required (it is what makes the origin bootc-managed)"

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
if [[ "$CHECK" == 0 ]]; then
    [[ -f "$IMAGE_META/manifest.json" && -f "$IMAGE_META/config.json" ]] ||
        die "no $IMAGE_META/{manifest,config}.json - stage the bundle first (stage-adopt-bundle.sh)"
    [[ -f "$BASE_LAYER" ]] || die "no base layer: $BASE_LAYER"
    [[ -x "$ADOPT" ]] || die "no executable adopt script at $ADOPT"
fi

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
# The image is flashed shrunk (see the shrink at the end), so the tablet needs the way back
# to the full partition baked in. Do it before the adoption commits /usr, so the physical
# root and the deployment both carry the unit.
GROW_SH="$ROOTFS_DIR/armada-growfs.sh"; GROW_UNIT="$ROOTFS_DIR/armada-growfs.service"
if [[ "$CHECK" == 0 ]]; then
    [[ -r "$GROW_SH" && -r "$GROW_UNIT" ]] || die "the repo is missing $GROW_SH or $GROW_UNIT"
    install -d -m 0755 "$MNT/usr/lib/armada"
    install -m 0755 "$GROW_SH" "$MNT/usr/lib/armada/armada-growfs.sh"
    install -m 0644 "$GROW_UNIT" "$MNT/usr/lib/systemd/system/armada-growfs.service"
    install -d -m 0755 "$MNT/usr/lib/systemd/system/sysinit.target.wants"
    ln -sf ../armada-growfs.service "$MNT/usr/lib/systemd/system/sysinit.target.wants/armada-growfs.service"
    install -d -m 0755 "$MNT/etc/armada"
    : > "$MNT/etc/armada/need-growfs"
    # /etc/armada is not what a composed boot reads, so arm a second marker under /var: the
    # stateroot var is seeded from the flat root's /var, so it follows the deployment.
    install -d -m 0755 "$MNT/var/lib/armada"
    : > "$MNT/var/lib/armada/need-growfs"
    log "baked armada-growfs.service, armed with /etc/armada/need-growfs and /var/lib/armada/need-growfs"
fi
if [[ "$CHECK" == 1 ]]; then
    [[ -d "$MNT/ostree/repo" ]] || die "$IMG has no /ostree/repo - it was never adopted, --check-only needs an adopted image"
elif [[ -d "$MNT/ostree/repo" ]]; then
    die "$IMG already has /ostree/repo - adopting twice is not supported, rebuild the flat root"
fi
# libostree insists that <sysroot>/boot/loader is a symlink (it writes loader.0/loader.1
# and points loader at the newest, which is why stage-1 reads /boot/loader.N/entries).
# A real directory there makes "ostree admin deploy" fail with "Not a symbolic link:
# boot/loader", so move it aside and say so instead of failing inside ostree.
if [[ "$CHECK" == 0 && -e "$MNT/boot/loader" && ! -L "$MNT/boot/loader" ]]; then
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

if [[ "$CHECK" == 0 ]]; then
    log "adopting offline"
    "$ADOPT" "${ARGS[@]}" 2>&1 | tee "${IMG_ABS}.adopt.log"
    if [[ "$DRY" == 1 ]]; then
        log "dry run only - nothing changed"
        exit 0
    fi
fi

# ---- what has to be true before this image goes to the tablet -----------------
fail=0
note() { if eval "$2"; then log "ok:   $1"; else log "FAIL: $1"; fail=$((fail + 1)); fi; }

status=$(ostree admin --sysroot="$MNT" status 2>&1)
# libostree lists each deployment as "  <stateroot> <deploy-id>.0" - the word
# "Deployment" is not in that output, which is what made this gate fail on a sysroot
# that was actually fine.
status_re=${STATUS_RE_TPL/@STATEROOT@/$STATEROOT}
note "ostree admin status lists a $STATEROOT deployment" \
     "grep -qE \"\$status_re\" <<<\"\$status\""
note "the origin is the container reference" \
     "grep -q 'container-image-reference' \"$MNT\"/ostree/deploy/$STATEROOT/deploy/*.origin"
note "/init is the stage-1 launcher" "[[ -x $MNT/init ]]"
note "stage-1 runtime is on the physical root" "[[ -x $MNT/usr/lib/armada/armada-ostree-stage1.sh ]]"
note "growfs unit is installed and wanted by sysinit.target" \
     "[[ -x $MNT/usr/lib/armada/armada-growfs.sh ]] && [[ -L $MNT/usr/lib/systemd/system/sysinit.target.wants/armada-growfs.service ]]"
note "confirm unit is wanted by basic.target" \
     "ls \"$MNT\"/ostree/deploy/$STATEROOT/deploy/*/etc/systemd/system/basic.target.wants/armada-ostree-confirm.service >/dev/null 2>&1"
marker=$(tr -d ' \t\r\n' < "$MNT/etc/armada/ostree-boot" 2>/dev/null)
want=yes; [[ "$DISARM" == 1 ]] && want=no
note "marker /etc/armada/ostree-boot is [$want]" "[[ \$marker == $want ]]"

# What has to fit is not the options line but the cmdline the payload packer assembles
# from it (bootimg-args puts ostree= first, drops console=ttyS0, merges rootflags=), and
# that lands in the 512 B cmdline field of the header-v0 ABL reads. Gate on the same
# function so a green image and the packer can never disagree about what fits.
BOOTIMG_LIB="$ROOTFS_DIR/../../../system_files/usr/lib/armada/bootimg-args"
if [[ -r "$BOOTIMG_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$BOOTIMG_LIB"
else
    log "note: cannot read $BOOTIMG_LIB - measuring the raw options line instead"
    ARMADA_CMDLINE_MAX=512
    armada_bootimg_cmdline() { printf '%s' "$1"; }
fi
bls=( "$MNT"/boot/loader*/entries/ostree-*.conf )
[[ -e "${bls[0]}" ]] || die "no BLS entries under $MNT/boot/loader*/entries - stage-1 has nothing to boot"
[[ -L "$MNT/boot/loader" ]] || log "note: $MNT/boot/loader is not a symlink; stage-1 globs boot/loader.N"
# Whether the header field can make this image unbootable depends on the board, and the
# image says so: /etc/armada/boot-method is "none" on TB320FC UFS (ABL takes kernel+DTB from
# the raw boot_ partition, stage-1 chooses init itself, and armada-bootimg-finalize is turned
# off exactly so it cannot run bootc rollback - PROGRESS A197/A207). Only the SD-card/ABL
# flow turns an options line into a /KERNEL, so only there is the length fatal.
bootmethod=$(tr -d ' \t\r\n' < "$MNT/etc/armada/boot-method" 2>/dev/null)
pay_fatal=1
if [[ "$bootmethod" == none ]]; then
    pay_fatal=0
    log "note: /etc/armada/boot-method is none here - no /KERNEL is built from these entries on this board"
fi
for f in "${bls[@]}"; do
    opts=$(sed -n 's/^options //p' "$f" | head -1)
    if ! pay=$(armada_bootimg_cmdline "$opts"); then
        log "FAIL: $(basename "$f") has no ostree= karg - the packer refuses to build /KERNEL from it"
        fail=$((fail + 1))
        continue
    fi
    log "BLS $(basename "$f"): options ${#opts} B, /KERNEL cmdline ${#pay} B (limit $ARMADA_CMDLINE_MAX)"
    if (( ${#pay} > ARMADA_CMDLINE_MAX )); then
        grep -q '^initrd ' "$f" ||
            log "       and there is no initrd line: when libostree finds no initramfs it writes
       its init=<deployment>/usr/lib/ostree/ostree-prepare-root shape, which costs 129 B alone"
        if (( pay_fatal )); then
            log "FAIL: /KERNEL cmdline would be ${#pay} B, over the ${ARMADA_CMDLINE_MAX} B header-v0 field"
            fail=$((fail + 1))
        else
            log "note: /KERNEL cmdline would be ${#pay} B, over ${ARMADA_CMDLINE_MAX} B; harmless while boot-method is none, fatal if that changes"
        fi
    fi
    [[ "$opts" == *"$ROOT_KARG"* ]] || { log "FAIL: $ROOT_KARG missing from $(basename "$f")"; fail=$((fail + 1)); }
done
# stage-1 and armada-ostree-bootlink pick the boot farm from the /boot/loader symlink, so
# verify the links for the bootversion this sysroot really uses (BLS adoption => boot.1).
bootv=0
[[ -L "$MNT/boot/loader" && "$(readlink "$MNT/boot/loader")" == *loader.1 ]] && bootv=1
farm=${FARM_GLOB_TPL/@BOOTV@/$bootv}
farm=${farm/@STATEROOT@/$STATEROOT}
# The stateroot lives under /ostree/boot.N (the symlink libostree maintains) or, if that
# link is gone, under /ostree/boot.N.M. Globbing both into one [ -d ] would hand test two
# words, so collect the candidates and check one at a time.
farm_dir=""
for cand in "$MNT"/ostree/$farm "$MNT"/ostree/boot."$bootv"/"$STATEROOT"; do
    [[ -d "$cand" ]] && { farm_dir="$cand"; break; }
done
note "the /ostree/boot.$bootv farm holds the $STATEROOT stateroot" "[[ -n \"$farm_dir\" ]]"
# What stage-1 resolves at boot is the path in the entry's own ostree= karg: the farm is
# boot.1.1/default/<bootcsum>/ (a real directory) and the <treebootserial> inside it is the
# symlink, so "-type l" one level down never matches. Following the entry cannot drift.
for f in "${bls[@]}"; do
    link=$(sed -n 's/.*ostree=\([^ ]*\).*/\1/p' "$f" | head -1)
    note "$(basename "$f") ostree= link resolves to a deployment" \
         "[[ -n \"$link\" && -d \"$MNT$link\" ]]"
done

if [[ "$CHECK" == 1 ]]; then
    umount "$MNT"
    trap - EXIT
    (( fail )) && die "$fail post-adoption checks failed on $IMG_ABS - this is not a bootable ostree image"
    echo "OSTREE_FIRST_CHECKS_OK $IMG_ABS"
    exit 0
fi

umount "$MNT"
trap - EXIT
e2fsck -f -y "$IMG_ABS" > /dev/null || die "e2fsck after the adoption failed"
tune2fs -L "$LABEL" "$IMG_ABS" > /dev/null || log "warning: could not re-apply label $LABEL"

# ---- make the image flashable ------------------------------------------------
# edl.py streams os.stat(file).st_size bytes and knows nothing about holes, and ext4 keeps an
# inode table at the start of every flex group, so a full-size root means streaming all
# 322 GiB of it. An e2image -r dump is not an escape: it is sparse over the same span and
# leaves the data blocks out, so a board flashed from it boots into a root of zeros. Shrink
# the filesystem instead - the used bytes become contiguous - and let armada-growfs.sh grow
# it back on the tablet's first boot.
if (( fail == 0 )) && [[ "$CHECK" == 0 && "$NOSHRINK" == 0 ]]; then
    command -v resize2fs >/dev/null || die "no resize2fs on this machine - pass --no-shrink and accept the slow install"
    e2fsck -f -y "$IMG_ABS" >/dev/null || die "e2fsck before the shrink failed"
    bsize=$(dumpe2fs -h "$IMG_ABS" 2>/dev/null | awk '/^Block size:/{print $3}')
    cur=$(dumpe2fs -h "$IMG_ABS" 2>/dev/null | awk '/^Block count:/{print $3}')
    min=$(resize2fs -P "$IMG_ABS" 2>/dev/null | awk '/Estimated minimum size of the filesystem/{print $NF}')
    [[ "$bsize" =~ ^[0-9]+$ && "$cur" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] ||
        die "cannot size $IMG_ABS: block size=$bsize count=$cur minimum=$min"
    target=$(( min + SHRINK_MARGIN * 2**30 / bsize ))
    if (( target < cur )); then
        resize2fs "$IMG_ABS" "$target" | tail -1 | sed 's/^/  /'
        e2fsck -f -y "$IMG_ABS" >/dev/null || die "e2fsck after the shrink failed"
        tune2fs -L "$LABEL" "$IMG_ABS" >/dev/null || log "warning: could not re-apply label $LABEL"
        log "shrunk $cur -> $(dumpe2fs -h "$IMG_ABS" | awk '/^Block count:/{print $3}') blocks;" \
            "the install streams $(( $(stat -c %s "$IMG_ABS") / 2**30 )) GiB"
        log "the tablet grows it back on first boot (marker /etc/armada/need-growfs)"
        # A relocation that broke the deployment has to fail here, not on the tablet.
        log "re-running the gates against the shrunk image"
        "$0" "$IMG_ABS" --check-only --stateroot "$STATEROOT" --label "$LABEL" --mnt "$MNT-recheck"
    else
        log "note: nothing to shrink (the filesystem already holds $cur blocks)"
    fi
fi
log "adopt log: ${IMG_ABS}.adopt.log"
df -h "$IMG_ABS" 2>/dev/null | tail -1 | sed 's/^/  /' || true
dumpe2fs -h "$IMG_ABS" 2>/dev/null | awk '/Block count|Free blocks/{print "  " $0}' || true

if (( fail )); then
    die "$fail post-adoption checks failed - do not push this image (log: ${IMG_ABS}.adopt.log)"
fi
echo "OSTREE_FIRST_OK $IMG_ABS"