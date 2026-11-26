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
set -euo pipefail

SRC=${SRC:-http://192.168.31.4:8791}
AUTH=${AUTH:-armada:armada}
IMAGE_REF=${IMAGE_REF:?IMAGE_REF=ostree-unverified-image:docker://192.168.31.4:5000/armada:<tag>}
D=${D:-/tmp/a207}
GO=0
for a in "$@"; do [ "$a" = --go ] && GO=1; done

get() { curl -fsS -u "$AUTH" -o "$2" "$SRC/$1"; }

mkdir -p "$D/imgmeta"
cd "$D"
# adopt.sh installs the stage-1 runtime from files that have to sit next to it
# (--stage1 install dies on a missing one even during --dry-run), so fetch the whole
# set rather than only the two that were needed before the runtime moved into the tree.
for f in armada-ostree-adopt.sh armada-ostree-stage1.sh armada-ostree-confirm.sh \
         armada-ostree-bootlink.sh armada-ostree-confirm.service init-ostree; do
    get "$f" "$f"
done
get imgmeta/manifest.json imgmeta/manifest.json
get imgmeta/config.json imgmeta/config.json
get base-layer.tar base-layer.tar
ls -l base-layer.tar imgmeta/manifest.json imgmeta/config.json

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
