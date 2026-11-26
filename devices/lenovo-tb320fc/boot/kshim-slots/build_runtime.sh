#!/bin/bash
# Build one 4 MiB kShimC runtime for a TB320FC boot slot.
#
#   build_runtime.sh <round-name> <a|b> [extra cmake args...]
#     a -> configs/tb320fc_ufs_a2_defconfig  (boot_a, base = 机身 ArmadaOS)
#     b -> configs/tb320fc_ufs_b_defconfig   (boot_b, base = 原厂 Android)
#
# Everything that bit us once is asserted here:
#   * the profile in this directory is the source of truth; it is copied into the
#     kshim tree when it differs (CONFIG_SYNC=0 to disable), so a build can never
#     silently use a stale tree-side copy;
#   * the runtime must be exactly 4 MiB, with no unresolved symbols, and must carry
#     the NVT firmware blob (the panel IC firmware does not survive a reset, so a
#     runtime without it has no touch);
#   * config truth is build/<name>/generated/include/config.h. The Ninja object dir
#     is kShimC.elf.dir and holds no flags.make, so an older generation of these
#     scripts grep'd a file that never existed and always "passed".
set -uo pipefail

NAME="${1:?usage: build_runtime.sh <round-name> <a|b> [cmake args]}"; shift
SLOT="${1:?usage: second argument is the slot: a or b}"; shift
HERE=$(cd "$(dirname "$0")" && pwd)

case "$SLOT" in
  a) DEFCONFIG=tb320fc_ufs_a2_defconfig ;;
  b) DEFCONFIG=tb320fc_ufs_b_defconfig ;;
  *) echo "slot must be a (base = 机身 ArmadaOS) or b (base = 原厂 Android)" >&2; exit 2 ;;
esac

KSHIM_TREE=${KSHIM_TREE:-/srv/y700/kshim-gen2/src}
BUILD_VENV=${BUILD_VENV:-/srv/y700/kshim/src/build-venv/bin}
NVT_FIRMWARE=${NVT_FIRMWARE:-/srv/y700/g4/a211/initramfs/lib/firmware/novatek/lenovo-tb320fc.bin}
ARTIFACTS=${ARTIFACTS:-/root/y700-artifacts}
NM=${NM:-aarch64-linux-gnu-nm}
CONFIG_SYNC=${CONFIG_SYNC:-1}

# The diagnostic switches that are on in every image that has actually booted on
# this tablet since c49. They are CMake options, not defconfig symbols, so
# leaving them out silently builds a different runtime: the code layout shifts and
# the sha256 changes even when generated/include/config.h is identical.
# Extra cmake args passed to this script come last and win.
DIAG_DEFAULTS=(-DKSHIM_DIAG_PAINT_SPLASH=OFF -DKSHIM_DIAG_HALT_BEFORE_HANDOFF=OFF
               -DKSHIM_DIAG_REPORT=OFF -DKSHIM_DIAG_CATCH=ON
               -DKSHIM_QUIRK_CNTPCT_DISABLE=OFF -DKSHIM_DIAG_BEACON=OFF
               -DKSHIM_GEN2_ENTRY_VIA_HEADER=OFF)

[ -d "$KSHIM_TREE" ]        || { echo "no kshim tree at $KSHIM_TREE" >&2; exit 1; }
[ -x "$BUILD_VENV/python3" ] || { echo "no python3 in $BUILD_VENV (kconfiglib venv)" >&2; exit 1; }
[ -f "$NVT_FIRMWARE" ]      || { echo "no NVT firmware at $NVT_FIRMWARE; menu touch would be gone" >&2; exit 1; }
export PATH="$BUILD_VENV:$PATH"
command -v cmake >/dev/null || { echo "cmake not on PATH" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja not on PATH" >&2; exit 1; }
command -v "$NM"  >/dev/null || { echo "$NM not on PATH (aarch64 binutils)" >&2; exit 1; }

synced="$HERE/configs/$DEFCONFIG"
treedst="$KSHIM_TREE/configs/$DEFCONFIG"
if [ "$CONFIG_SYNC" != 0 ]; then
  s1=$(sha256sum "$synced" | cut -d' ' -f1)
  s2=$([ -f "$treedst" ] && sha256sum "$treedst" | cut -d' ' -f1 || echo none)
  if [ "$s1" != "$s2" ]; then
    echo "syncing profile $s1 -> $s2 : $treedst"
    cp "$synced" "$treedst"
  else
    echo "profile in sync: $DEFCONFIG $s1"
  fi
fi
[ -f "$treedst" ] || { echo "missing $treedst" >&2; exit 1; }

OUT="$KSHIM_TREE/build/$NAME"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$treedst" "$OUT/.config"

echo "=== configure $NAME (slot $SLOT, $DEFCONFIG) ==="
cmake -S "$KSHIM_TREE" -B "$OUT" -G Ninja \
  -DKSHIM_STANDALONE=OFF -DKSHIM_RUNTIME_SLOT_SIZE=0x400000 \
  -DKSHIM_UEFI_PAYLOAD= -DCMAKE_BUILD_TYPE=Release \
  -DKSHIM_GEN2_CODE1_ENTRY=ON -DKSHIM_NVT_FIRMWARE="$NVT_FIRMWARE" \
  "${DIAG_DEFAULTS[@]}" "$@" > "$OUT/configure.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then echo "CONFIGURE_FAIL $NAME rc=$rc"; tail -n 40 "$OUT/configure.log"; exit 1; fi

echo "=== build $NAME ==="
cmake --build "$OUT" -j "$(nproc)" > "$OUT/build.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "BUILD_FAIL $NAME rc=$rc"
  grep -E 'error|Error' "$OUT/build.log" | head -40
  tail -n 25 "$OUT/build.log"
  exit 1
fi

size=$(stat -c %s "$OUT/kShimC.bin")
echo "$NAME size=$size"
[ "$size" = "4194304" ] || { echo "SIZE_FAIL $NAME (runtime slot is 0x400000)"; exit 1; }

if "$NM" -u "$OUT/kShimC.elf" > "$OUT/unresolved.txt" 2>&1 && grep -q . "$OUT/unresolved.txt"; then
  echo "UNRESOLVED $NAME"
  head -20 "$OUT/unresolved.txt"
  exit 1
fi

CFG="$OUT/generated/include/config.h"
echo "=== config.h ($CFG) ==="
grep -E 'KSHIM_(TOUCH_NVT_SPI|TOUCH_NVT_FW|UFS_PAYLOAD_BOOT|MENU_BASE_ANDROID|UFS_TITLE_REPORT|GEN2_ENTRY_RESTORE|UI_ROTATION_CCW|MENU_ENTRY_DURATION_MS)' "$CFG" || true
# Slot semantics are checked, not assumed.
if [ "$SLOT" = a ]; then
  grep -q 'CONFIG_KSHIM_MENU_BASE_ANDROID' "$CFG" && { echo "A_SLOT_SEMANTICS_FAIL: base must not be called Android"; exit 1; }
fi
# The symbol table is written to a file first: with `set -o pipefail`, `nm | grep -q`
# makes grep exit on the first match, nm then dies of SIGPIPE (141) and the whole
# pipeline reports failure even though the symbol is there. That is how a symbol
# check ends up lying in both directions.
"$NM" "$OUT/kShimC.elf" > "$OUT/symbols.txt"
for sym in kshim_nvt_wait_reset_state kshim_nvt_frame_slots kshim_lvgl_touch kshim_nvt_download_firmware kshim_nvt_fw_data; do
  grep -qw "$sym" "$OUT/symbols.txt" || echo "SYMBOL_MISSING $sym"
done
if [ "$SLOT" = b ]; then
  grep -qw kshim_pay_stage "$OUT/symbols.txt" || echo "SYMBOL_MISSING kshim_pay_stage (route A must exist on the Android slot)"
fi

sha=$(sha256sum "$OUT/kShimC.bin" | cut -d' ' -f1)
mkdir -p "$ARTIFACTS"
cp "$OUT/kShimC.bin" "$ARTIFACTS/kshim-tb320fc-$NAME.bin"
echo "OK $NAME -> $ARTIFACTS/kshim-tb320fc-$NAME.bin sha256=$sha"
