#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pack the state that belongs to the IMAGE into the two tars the ostree adoption stages.
#
# armada-ostree-adopt.sh takes two directories that must come from the image and never
# from the running root:
#   --factory-etc DIR   the image's /etc.  A flat root has no /usr/etc, and only the
#                       first deployment gets away without one: every later one dies in
#                       "During /etc merge: While computing configuration diff: ...
#                       /usr/etc: No such file or directory" (PROGRESS A220).
#   --image-var DIR     the image's /var/home and /var/roothome.  The image ships the
#                       factory Steam client there (build_files/30-install-steam-session.sh)
#                       and Armada tools' repair exports exactly that path out of the
#                       booted commit, so without it the commit carries an empty /var
#                       skeleton and repair reports "No such file or directory:
#                       /var/home/armada" (PROGRESS A221).
#
# Both have to reach the tablet as tarballs.  Until now the commands that make them were
# a comment inside adopt-run-board.sh, which is how a re-adoption ends up with half a
# bundle; this script is what build-ufs-root.sh and stage-adopt-bundle.sh call instead.
#
# Usage:
#   pack-image-state.sh --out DIR (--image REF | --tree DIR) [options]
#
#   --image REF         podman image to mount; it is mounted and unmounted here
#   --tree DIR          an already-mounted image tree (build-ufs-root.sh has one)
#   --var-paths "P ..." tree paths for the /var tar (default: var/home var/roothome)
#   --min-entries N     a tar with no more than N entries is refused (default 10).
#                       Deliberately a "you pointed at the wrong directory" level rather
#                       than a content check: a real image /etc has ~200 top-level
#                       entries and /var/home alone has ~20 000 files.
#   --require-steam     fail instead of warn when the var tar has no factory Steam
#
# Writes factory-etc.tar, factory-var.tar, factory-state.sha256 and factory-state.txt
# into --out.  Each tar is written as <name>.tmp and renamed only after it has been read
# back through tar -t, so an out-of-disk or interrupted run never leaves a truncated
# archive for the board to download.
set -euo pipefail

OUT=""; IMAGE=""; TREE=""; MIN_ENTRIES=10; REQUIRE_STEAM=0; MOUNTED=0
VAR_PATHS=(var/home var/roothome)

log() { echo "pack-image-state: $*"; }
die() { echo "pack-image-state: $*" >&2; exit 1; }
usage() {
    echo "usage: $(basename "$0") --out DIR (--image REF | --tree DIR)" \
         "[--var-paths \"...\"] [--min-entries N] [--require-steam]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)           OUT="${2:?--out needs a directory}"; shift 2 ;;
        --out=*)         OUT="${1#*=}"; shift ;;
        --image)         IMAGE="${2:?--image needs a reference}"; shift 2 ;;
        --image=*)       IMAGE="${1#*=}"; shift ;;
        --tree)          TREE="${2:?--tree needs a directory}"; shift 2 ;;
        --tree=*)        TREE="${1#*=}"; shift ;;
        --var-paths)     read -r -a VAR_PATHS <<<"${2:?--var-paths needs a list}"; shift 2 ;;
        --var-paths=*)   read -r -a VAR_PATHS <<<"${1#*=}"; shift ;;
        --min-entries)   MIN_ENTRIES="${2:?--min-entries needs a number}"; shift 2 ;;
        --min-entries=*) MIN_ENTRIES="${1#*=}"; shift ;;
        --require-steam) REQUIRE_STEAM=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage; die "unknown argument $1" ;;
    esac
done

[[ -n "$OUT" ]] || { usage; die "--out DIR is required"; }
[[ -z "$IMAGE" || -z "$TREE" ]] || die "--image and --tree are alternatives, not both"
[[ -n "$IMAGE$TREE" ]] || { usage; die "give --image REF or --tree DIR"; }
[[ "$MIN_ENTRIES" =~ ^[0-9]+$ ]] || die "--min-entries has to be a number, got $MIN_ENTRIES"

if [[ -n "$IMAGE" ]]; then
    command -v podman >/dev/null ||
        die "no podman on this host; mount $IMAGE yourself and pass --tree DIR"
    TREE=$(podman image mount "$IMAGE" 2>/dev/null | head -1) || die "cannot mount image $IMAGE"
    [[ -n "$TREE" ]] || die "cannot mount image $IMAGE"
    MOUNTED=1
fi
cleanup() {
    [[ "$MOUNTED" == 1 ]] && podman image unmount "$IMAGE" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

[[ -d "$TREE" ]] || die "no such image tree: $TREE"
[[ -f "$TREE/usr/lib/os-release" ]] ||
    die "$TREE is not an image root: no usr/lib/os-release (expected a mounted image or a rootfs tree)"

TREE_ABS=$(realpath "$TREE")
SOURCE_LABEL="${IMAGE:-$TREE_ABS}"
mkdir -p "$OUT" || die "cannot create $OUT"
OUT_ABS=$(realpath "$OUT")
case "$OUT_ABS" in
    "$TREE_ABS"/*|"$TREE_ABS") die "--out $OUT is inside the tree being packed - the tar would eat itself" ;;
esac

# List the archive into a file and grep the file.  `tar -t | grep -q` dies under pipefail
# because grep exits early and tar takes SIGPIPE (the same trap the kshim build scripts
# hit with nm | grep, PROGRESS A203), and that would read as a packaging failure.
pack() { # pack NAME TARFILE PATH...
    local name=$1 tarfile=$2; shift 2
    local -a present=()
    local p
    for p in "$@"; do
        [[ -e "$TREE/$p" ]] && present+=("$p")
    done
    if [[ ${#present[@]} -eq 0 ]]; then
        die "$name: none of [$*] exists under $TREE (top level: $(ls "$TREE" 2>/dev/null | tr '\n' ' '))"
    fi
    local tmp="$tarfile.tmp" list entries
    rm -f "$tmp"
    tar -C "$TREE" -cf "$tmp" -- "${present[@]}" || die "$name: tar failed writing $tmp"
    list=$(mktemp)
    if ! tar -tf "$tmp" >"$list" 2>/dev/null; then
        rm -f "$tmp" "$list"
        die "$name: $tmp cannot be read back, it is not a valid tar"
    fi
    entries=$(wc -l <"$list" | tr -dc '0-9')
    if [[ "$entries" -le "$MIN_ENTRIES" ]]; then
        rm -f "$tmp" "$list"
        die "$name: only $entries entries from [${present[*]}] under $TREE - a mistyped or empty source directory looks like this"
    fi
    if ! grep -qF -- "${present[0]}/" "$list"; then
        rm -f "$tmp" "$list"
        die "$name: ${present[0]} is missing from the archive it just made"
    fi
    if [[ "$name" == "var" ]] && ! grep -qF "var/home/armada/.local/share/Steam/" "$list"; then
        if [[ "$REQUIRE_STEAM" == 1 ]]; then
            rm -f "$tmp" "$list"
            die "var: this image has no var/home/armada/.local/share/Steam, so Armada tools' Steam repair would have nothing to export"
        fi
        log "warning: the var tar carries no factory Steam; repair will report it for this boot"
    fi
    rm -f "$list"
    mv -f "$tmp" "$tarfile" || die "$name: cannot move $tmp into place"
    log "$name: $(du -h "$tarfile" | cut -f1) entries=$entries paths=[${present[*]}]"
    printf '%s %s entries=%s\n' "$name" "$(basename "$tarfile")" "$entries" >>"$OUT_ABS/.state-summary"
}

rm -f "$OUT_ABS/.state-summary"
log "source: $SOURCE_LABEL"
pack etc "$OUT_ABS/factory-etc.tar" etc
pack var "$OUT_ABS/factory-var.tar" "${VAR_PATHS[@]}"

( cd "$OUT_ABS" && sha256sum factory-etc.tar factory-var.tar >factory-state.sha256 )
{
    echo "source=$SOURCE_LABEL"
    echo "packed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "var_paths=${VAR_PATHS[*]}"
    echo "min_entries=$MIN_ENTRIES"
    cat "$OUT_ABS/.state-summary"
} >"$OUT_ABS/factory-state.txt"
rm -f "$OUT_ABS/.state-summary"

log "bundle: $OUT_ABS"
cat "$OUT_ABS/factory-state.txt"
echo "IMAGE_STATE_OK $OUT_ABS"