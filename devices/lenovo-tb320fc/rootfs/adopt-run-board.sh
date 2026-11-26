#!/usr/bin/env bash
# Run armada-ostree-adopt.sh on the tablet, in the order that is safe there.
#
# Why a wrapper (PROGRESS A207): three of the steps are easy to fumble by hand and
# each one has already cost a debugging cycle on HA1WZJJ5.
#   * /etc/armada/boot-method has to say none BEFORE anything stages a deployment:
#     armada-bootimg-finalize defaults to abl, its update fails on a board with no
#     ESP, and its failure branch runs `bootc rollback` on the deployment we just
#     made (PROGRESS A197).
#   * the image metadata and the base-layer tar have to be the exact bytes the
#     registry serves - adopt.sh hashes the tar against manifest layer[0].
#   * adopt.sh is additive and fail-safe, so the right first run is --dry-run:
#     it prints the ostree commit it would make without touching the sysroot.
#
#   adopt-run-board.sh                 # fetch, boot-method, dry-run, stop
#   adopt-run-board.sh --go            # same, then the real adoption
#   adopt-run-board.sh --clean-state   # drop the staged image state again
set -euo pipefail

SRC=${SRC:-http://192.168.31.4:8791}
AUTH=${AUTH:-armada:armada}
IMAGE_REF=${IMAGE_REF:?IMAGE_REF=ostree-unverified-image:docker://192.168.31.4:5000/armada:<tag>}
D=${D:-/tmp/a207}
GO=0
CLEAN=0
for a in "$@"; do
    [ "$a" = --go ] && GO=1
    [ "$a" = --clean-state ] && CLEAN=1
done
if [ "$CLEAN" = 1 ]; then
    # The staged image state is several GB on a board that needs it exactly once; this is
    # how it gets reclaimed after an adoption instead of being found again months later.
    V=${V:-/var/usrlocal/armada-adopt}
    rm -rf "$V/var" "$V/etc" "$V/factory-var.tar" "$V/factory-etc.tar" "$V/factory-state.sha256"
    echo "cleaned the staged image state under $V ($(du -sh "$V" 2>/dev/null | cut -f1) left)"
    exit 0
fi

get() { curl -fsS -u "$AUTH" -o "$2" "$SRC/$1"; }

mkdir -p "$D/imgmeta"
cd "$D"
# adopt.sh installs the stage-1 runtime from files that have to sit next to it
# (--stage1 install dies on a missing one even during --dry-run), so fetch the whole
# set rather than only the two that were needed before the runtime moved into the tree.
for f in armada-ostree-adopt.sh armada-ostree-stage1.sh armada-ostree-confirm.sh \
         armada-ostree-bootlink.sh armada-ostree-confirm.service init-ostree \
         image-state-fetch.sh; do
    get "$f" "$f"
done
get imgmeta/manifest.json imgmeta/manifest.json
get imgmeta/config.json imgmeta/config.json
get base-layer.tar base-layer.tar
ls -l base-layer.tar imgmeta/manifest.json imgmeta/config.json

# The image's own /var and /etc, each in its own tar. Neither one is machine state:
# the image ships the factory Steam client under /var/home/armada/.local/share/Steam
# (build_files/30-install-steam-session.sh) and Armada tools' Steam repair exports
# exactly that path out of the booted commit - without it the commit carries an empty
# /var skeleton and repair fails with "No such file or directory: /var/home/armada"
# (PROGRESS A221). A flat root has no /usr/etc either, which is what the /etc merge of
# the *second* deployment dies on (PROGRESS A220).
#
# pack-image-state.sh / stage-adopt-bundle.sh produce both tars next to base-layer.tar,
# plus factory-state.sha256 so a 3.5 GB download over Wi-Fi is verified before it is
# unpacked. They land under $V because /tmp on this board is tmpfs.
V=${V:-/var/usrlocal/armada-adopt}
mkdir -p "$V"

# image-state-fetch.sh does the transfer, the factory-state.sha256 check and the unpack.
# It exits 1 when the bundle serves no such tar (a warning the adoption can live with) and
# 2 when the bytes or the free space are wrong (which the tablet cannot fix by itself).
fetch_state() { # fetch_state <tar> <anchor directory> <spare bytes wanted>
    "$D/image-state-fetch.sh" --src "$SRC" --auth "$AUTH" --out "$V" \
        --tar "$1" --anchor "$2" --headroom "$3"
}

if dir=$(fetch_state factory-var.tar var 2147483648); then
    IMAGE_VAR_DIR="$dir"
else
    case $? in
        1) echo "warning: $SRC serves no factory-var.tar."
           echo "         the commit will carry an empty /var skeleton, and Armada tools'"
           echo "         Steam repair will have no factory client to export." ;;
        *) exit 1 ;;
    esac
fi
if dir=$(fetch_state factory-etc.tar etc 67108864); then
    FACTORY_ETC_DIR="$dir"
else
    case $? in
        1) echo "note: $SRC serves no factory-etc.tar. The first deployment works without"
           echo "      it; a second one fails in the /etc merge unless this root already"
           echo "      has /usr/etc." ;;
        *) exit 1 ;;
    esac
fi

# boot-method: the file decides whether bootc is allowed to touch the boot image.
# none = kernel/DTB/initramfs are written out of band into the raw boot partition.
mkdir -p /etc/armada
if [ ! -s /etc/armada/boot-method ]; then
    printf 'none\n' > /etc/armada/boot-method
fi
echo "boot-method=$(cat /etc/armada/boot-method)"

# The registry is plain HTTP on the LAN; this drop-in is development-only and
# should be removed when the image moves back to ghcr (PROGRESS A197).
mkdir -p /etc/containers/registries.conf.d
grep -qs '192.168.31.4' /etc/containers/registries.conf.d/99-lan-armada.conf ||
    printf '[[registry]]\nlocation = "192.168.31.4:5000"\ninsecure = true\n' \
        > /etc/containers/registries.conf.d/99-lan-armada.conf

ARGS=(--sysroot / --from flat --stage1 install
      --image-ref "$IMAGE_REF"
      --image-meta "$D/imgmeta" --base-layer "$D/base-layer.tar"
      --root-karg root=PARTLABEL=linuxroot)
if [ -n "${IMAGE_VAR_DIR:-}" ]; then
    ARGS+=(--image-var "$IMAGE_VAR_DIR")
fi
if [ -n "${FACTORY_ETC_DIR:-}" ]; then
    ARGS+=(--factory-etc "$FACTORY_ETC_DIR")
fi

echo "--- dry run"
bash armada-ostree-adopt.sh "${ARGS[@]}" --dry-run 2>&1 | tail -40
if [ "$GO" != 1 ]; then
    echo "ADOPT_DRY_OK  re-run with --go to apply"
    exit 0
fi

echo "--- adopt"
bash armada-ostree-adopt.sh "${ARGS[@]}" 2>&1 | tail -60
echo "--- verify"
ostree admin status 2>&1 | head -20
bootc status 2>&1 | head -30
findmnt -no SOURCE,FSTYPE / || true
ls -l /init /sysroot/ostree/repo 2>&1 | head -6
echo "ADOPT_RUN_DONE"
