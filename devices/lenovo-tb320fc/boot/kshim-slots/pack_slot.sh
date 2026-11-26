#!/bin/bash
# Pack a kShimC runtime into a TB320FC boot slot container.
#
#   pack_slot.sh <a|b> <runtime.bin> <out.img> [reference.report.json]
#
# Slot facts that must not be mixed up:
#   * --stock-boot is the pristine backup of THAT slot (A: boot_a-live.img,
#     B: boot_b-live.img). Packing a live image that already carries a shim stacks
#     two runtimes and the second one is never reached.
#   * --base-name is what the OPPOSITE slot's menu will show for the staged copy:
#     src/core/main.c labels a route-A row with "the name that slot's own manifest
#     gave its base image". A says ArmadaOS（机身）, B says Android（机身）.
#   * --entry-code1 always: the Gen2 entry protocol patches the ARM64 header code1
#     branch (patching the EFI-stub entry left the shim unreached on this board).
#   * Reports are only comparable within one slot; A and B have different layouts
#     (A: shim_off=61669376 manifest_off=65863680 tail_off=65933312).
set -uo pipefail

SLOT="${1:?usage: pack_slot.sh <a|b> <runtime.bin> <out.img> [reference.report.json]}"
RUNTIME="${2:?runtime bin (exactly 4 MiB, from build_runtime.sh)}"
OUT="${3:?output image path}"
HERE=$(cd "$(dirname "$0")" && pwd)

case "$SLOT" in
  a) STOCK=${STOCK:-/srv/y700/g4/a149/boot_a-live.img}
     BASE_NAME=${BASE_NAME:-ArmadaOS（机身）}
     REF=${4:-/srv/y700/g4/a149/boot_a-c61a.img.report.json} ;;
  b) STOCK=${STOCK:-/srv/y700/g4/a149/boot_b-live.img}
     BASE_NAME=${BASE_NAME:-Android（机身）}
     REF=${4:-/srv/y700/g4/a149/boot_b-c61e.img.report.json} ;;
  *) echo "slot must be a or b" >&2; exit 2 ;;
esac

REPO=${REPO:-/srv/y700/gen2/repo}
PACKER=$REPO/devices/lenovo-tb320fc/boot/build_android_boot.py
AVBTOOL=${AVBTOOL:-$REPO/packages/kshim-tools/vendor/avbtool.py}
PY=${PY:-/srv/y700/kshim/src/build-venv/bin/python3}

[ -f "$RUNTIME" ] || { echo "no runtime at $RUNTIME" >&2; exit 1; }
[ -f "$STOCK" ]   || { echo "no pristine stock backup at $STOCK (fetch one first; never pack a packed image)" >&2; exit 1; }
[ "$(stat -c %s "$RUNTIME")" = 4194304 ] || { echo "runtime is not 4 MiB" >&2; exit 1; }

echo "slot      : $SLOT"
echo "stock     : $STOCK ($(sha256sum "$STOCK" | cut -c1-16)…)"
echo "runtime   : $RUNTIME ($(sha256sum "$RUNTIME" | cut -c1-16)…)"
echo "base-name : $BASE_NAME"

"$PY" -B "$PACKER" \
  --stock-boot "$STOCK" \
  --runtime "$RUNTIME" \
  --avbtool "$AVBTOOL" \
  --entry-code1 \
  --base-name "$BASE_NAME" \
  --out "$OUT" || exit 1

sha256sum "$OUT" | tee "$OUT.sha256"
if [ -f "$REF" ]; then
  echo "== report diff vs $(basename "$REF")"
  python3 "$HERE/compare_reports.py" "$REF" "$OUT.report.json" || exit 1
else
  echo "no reference report at $REF; skipping the layout diff"
fi
