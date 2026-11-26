#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Stage everything armada-ostree-adopt.sh needs on the tablet into one served directory.
#
# The adoption consumes four image-derived inputs plus the scripts it runs:
#   imgmeta/{manifest,config}.json   the exact bytes the registry serves - bootc resolves
#                                    the digest of this document and nothing else
#   base-layer.tar                   layer[0] of that manifest, which libostree wants
#                                    under the blob ref ostree-ext names layers by
#   factory-etc.tar                  the image's /etc      (PROGRESS A220: the second
#                                    deployment has no /usr/etc to merge against)
#   factory-var.tar                  the image's /var/home + /var/roothome, i.e. the
#                                    factory Steam client that Armada tools' repair
#                                    exports (PROGRESS A221)
# The first two came from a script that only ever existed in /srv/y700 on the build
# machine, and the last two from a comment. That is how a re-adoption ends up shipping a
# commit with an empty /var, and how the tablet spends 20 minutes on Wi-Fi finding out.
# This is the build-flow entry point: one command, and it fails locally when the bundle
# would be incomplete.
#
# Usage: stage-adopt-bundle.sh <tag> [options]
#   --out DIR        bundle directory (default $DEFAULT_OUT)
#   --reg HOST:PORT  the LAN registry the image was pushed to (default $DEFAULT_REG)
#   --image REF      local podman image for the factory state tars; by default the tag
#                    itself, falling back to "<tag>-rootfs"
#   --chunked DIR    chunkah OCI dir whose blobs/sha256 already hold layer[0]
#   --no-state       skip the two factory state tars (base layer + metadata only)
#   --allow-no-steam turn the factory-Steam check from an error into a warning
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
ROOTFS_DIR="$ROOT_DIR/devices/lenovo-tb320fc/rootfs"
DEFAULT_OUT=/srv/y700/a207/serve
DEFAULT_REG=192.168.31.4:5000

OUT="$DEFAULT_OUT"; REG="$DEFAULT_REG"; IMAGE=""; CHUNKED=""; STATE=1; REQUIRE_STEAM=1
log() { echo "stage-adopt-bundle: $*"; }
die() { echo "stage-adopt-bundle: $*" >&2; exit 1; }

TAG="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)            OUT="${2:?}"; shift 2 ;;
        --out=*)          OUT="${1#*=}"; shift ;;
        --reg)            REG="${2:?}"; shift 2 ;;
        --reg=*)          REG="${1#*=}"; shift ;;
        --image)          IMAGE="${2:?}"; shift 2 ;;
        --image=*)        IMAGE="${1#*=}"; shift ;;
        --chunked)        CHUNKED="${2:?}"; shift 2 ;;
        --chunked=*)      CHUNKED="${1#*=}"; shift ;;
        --no-state)       STATE=0; shift ;;
        --allow-no-steam) REQUIRE_STEAM=0; shift ;;
        -h|--help)        sed -n '3,32p' "$0"; exit 0 ;;
        *)                die "unknown argument $1" ;;
    esac
done
[[ -n "$TAG" ]] || { echo "usage: $(basename "$0") <tag> [options]" >&2; exit 1; }

for tool in skopeo jq sha256sum curl; do
    command -v "$tool" >/dev/null || die "$tool is not installed on this host"
done

mkdir -p "$OUT/imgmeta" || die "cannot create $OUT"
IMG="docker://$REG/armada:$TAG"

# --- image metadata: straight from the registry, because the manifest digest has to be
# --- the one bootc resolves later.
skopeo inspect --raw --tls-verify=false "$IMG" >"$OUT/imgmeta/manifest.json" ||
    die "cannot read the manifest of $IMG (is it pushed? tag: $TAG)"
skopeo inspect --config --tls-verify=false "$IMG" >"$OUT/imgmeta/config.json" ||
    die "cannot read the config of $IMG"
jq -e '(.layers | length) > 1' "$OUT/imgmeta/manifest.json" >/dev/null ||
    die "$IMG is not a chunked image: it has one layer, and the adoption needs the base layer separately"
jq -e '.architecture == "arm64"' "$OUT/imgmeta/config.json" >/dev/null ||
    die "$IMG is not arm64 - the tablet cannot deploy it"

FIRST=$(jq -r '.layers[0].digest' "$OUT/imgmeta/manifest.json")
DIGEST=${FIRST#sha256:}
log "layer[0]: $FIRST ($(jq -r '.layers[0].mediaType' "$OUT/imgmeta/manifest.json"))"

# --- base layer: prefer the chunkah output that produced this manifest, otherwise pull
# --- the blobs out of the registry. Either way the digest check below is the same check
# --- adopt.sh runs, so a wrong file fails here rather than on the tablet.
if [[ -n "$CHUNKED" && -f "$CHUNKED/blobs/sha256/$DIGEST" ]]; then
    cp -f "$CHUNKED/blobs/sha256/$DIGEST" "$OUT/base-layer.tar"
elif [[ -f "${CHUNKED:-/srv/y700/g7/out/chunked}/blobs/sha256/$DIGEST" ]]; then
    cp -f "${CHUNKED:-/srv/y700/g7/out/chunked}/blobs/sha256/$DIGEST" "$OUT/base-layer.tar"
else
    log "fetching layer blobs from $REG"
    rm -rf "$OUT/dl"
    skopeo copy --tls-verify=false "$IMG" "dir:$OUT/dl" >/dev/null || die "skopeo copy failed"
    [[ -f "$OUT/dl/$DIGEST" ]] || die "$IMG does not serve a blob with digest $DIGEST"
    mv -f "$OUT/dl/$DIGEST" "$OUT/base-layer.tar"
    rm -rf "$OUT/dl"
fi
got=$(sha256sum "$OUT/base-layer.tar" | cut -d' ' -f1)
[[ "sha256:$got" == "$FIRST" ]] ||
    die "base-layer.tar is not this manifest's base layer: got sha256:$got want $FIRST"
log "base-layer.tar $(du -h "$OUT/base-layer.tar" | cut -f1)"

# --- the scripts the board runs, from this checkout, so the bundle and the repo cannot
# --- drift apart (adopt-run-board.sh fetches exactly this list).
BOARD_FILES=(armada-ostree-adopt.sh armada-ostree-stage1.sh armada-ostree-bootlink.sh
             armada-ostree-confirm.sh armada-ostree-confirm.service init-ostree
             boot-forensics.sh ostree-arm-reboot.sh)
for f in "${BOARD_FILES[@]}"; do
    [[ -f "$ROOTFS_DIR/$f" ]] || die "the repo has no devices/lenovo-tb320fc/rootfs/$f"
    install -m 0755 "$ROOTFS_DIR/$f" "$OUT/$f"
done
log "staged ${#BOARD_FILES[@]} board scripts from $ROOTFS_DIR"

# --- the image-owned state. This is the step that used to be a comment.
if [[ "$STATE" == 1 ]]; then
    [[ -n "$IMAGE" ]] || IMAGE="localhost/armada:$TAG"
    if ! podman image exists "$IMAGE" 2>/dev/null; then
        if podman image exists "localhost/armada:$TAG-rootfs" 2>/dev/null; then
            IMAGE="localhost/armada:$TAG-rootfs"
            log "no local $TAG, using the -rootfs build of it"
        else
            die "no local image $IMAGE to pack the factory state from (pass --image REF or --no-state)"
        fi
    fi
    args=(--image "$IMAGE" --out "$OUT")
    [[ "$REQUIRE_STEAM" == 1 ]] && args+=(--require-steam)
    "$ROOTFS_DIR/pack-image-state.sh" "${args[@]}" ||
        die "pack-image-state failed for $IMAGE - the bundle would be missing /etc or /var"
else
    log "skipping the factory state tars (--no-state): the commit will carry an empty /var"
fi

# --- what the board needs to know to run the adoption.
{
    echo "tag=$TAG"
    echo "registry=$REG"
    echo "image-ref=ostree-unverified-image:docker://$REG/armada:$TAG"
    echo "staged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "base_layer=$FIRST"
    for f in factory-etc.tar factory-var.tar; do
        [[ -f "$OUT/$f" ]] && echo "$f=$(du -h "$OUT/$f" | cut -f1)"
    done
    echo
    echo "run on the tablet:"
    echo "  SRC=http://$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p;q') \\"
    echo "  IMAGE_REF=ostree-unverified-image:docker://$REG/armada:$TAG bash adopt-run-board.sh --go"
} >"$OUT/BUNDLE.txt"
cat "$OUT/BUNDLE.txt"
echo "STAGE_ADOPT_OK $TAG"