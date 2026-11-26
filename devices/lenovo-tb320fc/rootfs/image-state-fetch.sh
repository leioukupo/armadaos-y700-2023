#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fetch, verify and unpack one image-state tar from the adoption bundle.
#
# adopt-run-board.sh used to inline this, which left the three failure modes of a 3.5 GB
# download over Wi-Fi (a truncated body, a root that is too full, and bytes that do not
# match what the build machine wrote) testable only on the tablet. This is that part as a
# unit with an exit code per mode; the wrapper decides what to do about each.
#
# Usage:
#   image-state-fetch.sh --src URL --auth user:pass --out DIR \
#                        --tar NAME --anchor DIRNAME [--headroom BYTES] [--quiet]
#
# stdout on success is the directory the anchor landed in - that is exactly the path
# adopt.sh wants for --image-var / --factory-etc.
#
# exit codes:
#   0 staged
#   1 the bundle does not serve this tar at all (not an error the tablet can fix)
#   2 a hard failure: no space, sha mismatch, or the archive has no anchor directory
set -euo pipefail

SRC=""; AUTH=""; OUT=""; NAME=""; ANCHOR=""; HEADROOM=67108864; QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)      SRC="${2:?--src needs a url}"; shift 2 ;;
        --src=*)    SRC="${1#*=}"; shift ;;
        --auth)     AUTH="${2:?--auth needs user:pass}"; shift 2 ;;
        --auth=*)   AUTH="${1#*=}"; shift ;;
        --out)      OUT="${2:?--out needs a directory}"; shift 2 ;;
        --out=*)    OUT="${1#*=}"; shift ;;
        --tar)      NAME="${2:?--tar needs a file name}"; shift 2 ;;
        --tar=*)    NAME="${1#*=}"; shift ;;
        --anchor)   ANCHOR="${2:?--anchor needs a directory name}"; shift 2 ;;
        --anchor=*) ANCHOR="${1#*=}"; shift ;;
        --headroom) HEADROOM="${2:?--headroom needs bytes}"; shift 2 ;;
        --headroom=*) HEADROOM="${1#*=}"; shift ;;
        --quiet)    QUIET=1; shift ;;
        -h|--help)  sed -n '3,20p' "$0"; exit 0 ;;
        *)          echo "image-state-fetch: unknown argument $1" >&2; exit 2 ;;
    esac
done
for need in SRC OUT NAME ANCHOR; do
    [[ -n "${!need}" ]] || { echo "image-state-fetch: --${need,,} is required" >&2; exit 2; }
done
[[ "$HEADROOM" =~ ^[0-9]+$ ]] || { echo "image-state-fetch: --headroom must be a number" >&2; exit 2; }

say() { [[ "$QUIET" == 1 ]] || echo "image-state-fetch: $*" >&2; }
bad() { echo "image-state-fetch: $*" >&2; exit 2; }

curl_auth() { if [[ -n "$AUTH" ]]; then curl -u "$AUTH" "$@"; else curl "$@"; fi; }

# --- is it there, and how big?
headers=$(curl_auth -fsIL "$SRC/$NAME" 2>/dev/null) || exit 1
bytes=$(printf '%s\n' "$headers" |
    awk 'BEGIN{IGNORECASE=1} /^content-length:/{v=$2} END{print v+0}')
say "$NAME: ${bytes:-unknown} bytes"

# --- the download and the unpack both need room, so check before starting a transfer
# --- that would fill the root and leave a half-written tar behind.
mkdir -p "$OUT" || bad "cannot create $OUT"
free=$(df -B1 --output=avail "$OUT" | tail -1 | tr -dc '0-9')
need=$(( ${bytes:-0} * 2 + HEADROOM ))
if [[ "${free:-0}" -lt "$need" ]]; then
    bad "not enough room under $OUT for $NAME: ${free} free, needs about ${need}"
fi

curl_auth -fsS -o "$OUT/$NAME" "$SRC/$NAME" || bad "cannot download $SRC/$NAME"

# --- integrity: the bundle carries factory-state.sha256 next to the tars. Verifying is
# --- optional (an older bundle has no such file), failing one is not.
if curl_auth -fsS -o "$OUT/factory-state.sha256" "$SRC/factory-state.sha256" 2>/dev/null &&
   grep -q " $NAME\$" "$OUT/factory-state.sha256"; then
    if ! ( cd "$OUT" && grep " $NAME\$" "$OUT/factory-state.sha256" | sha256sum -c --quiet - ); then
        rm -f "$OUT/$NAME"
        bad "$NAME does not match factory-state.sha256: the download is damaged, it was removed"
    fi
    say "$NAME sha256 verified"
else
    say "no factory-state.sha256 for $NAME in the bundle, downloading it unchecked"
fi

# --- unpack: pack-image-state.sh writes each archive with its own top-level directory,
# --- which is what lets this extract into $OUT and hand back $OUT/$ANCHOR.
rm -rf "$OUT/$ANCHOR"
tar -xf "$OUT/$NAME" -C "$OUT" || bad "cannot extract $OUT/$NAME"
[[ -d "$OUT/$ANCHOR" ]] || bad "$NAME did not contain a $ANCHOR/ directory"

say "factory /$ANCHOR staged in $OUT/$ANCHOR ($(find "$OUT/$ANCHOR" -mindepth 1 -maxdepth 1 | wc -l) top-level entries)"
echo "$OUT/$ANCHOR"
exit 0