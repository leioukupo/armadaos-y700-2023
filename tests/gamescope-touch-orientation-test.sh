#!/usr/bin/env bash
#
# Steam-mode touchscreen rotation on the Legion Y700 Gen2 depends on gamescope
# pairing the SPI digitizer with the internal connector: only then does
# wlserver_touchdown apply the connector orientation, and without it touch lands
# on the unrotated (portrait) coordinates of a rotated (landscape) output.
#
# That pairing is a gamescope package patch, not a system_files setting, so it is
# easy to lose silently: the patch sat in the tree while the published RPM kept
# being rebuilt from a cached package hash that predated it. Guard the chain here
# - the patch is shipped, it really teaches the heuristic about the spi bus, the
# patch list and its record agree, and nothing reintroduces a libinput rotation
# matrix that would turn the Plasma desktop coordinates twice.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GS_PATCH_DIR="$ROOT/packages/gamescope/patches"
GS_DOC="$ROOT/packages/gamescope/PATCHES.md"
SPI_PATCH="$GS_PATCH_DIR/0035-wlserver-associate-spi-touchscreens-with-internal-display.patch"
STEAM_SESSION="$ROOT/system_files/usr/share/gamescope-session-plus/sessions.d/steam"
PROFILE="$ROOT/system_files/usr/lib/armada/devices/lenovo-tb320fc.conf"
RULES_DIR="$ROOT/system_files/usr/lib/udev/rules.d"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s: got "%s" want "%s"\n' "$3" "$1" "$2" >&2
        exit 1
    fi
    printf 'ok   %s\n' "$3"
}

for f in "$GS_DOC" "$SPI_PATCH" "$STEAM_SESSION" "$PROFILE" "$RULES_DIR"; do
    [[ -r "$f" ]] || fail "missing $f"
done
[[ -r "$RULES_DIR/99-armada-tb323fu-virtual-touch.rules" ]] ||
    fail "missing the TB323FU virtual touch rule"

# --- the SPI association patch is shipped and still does the right thing ------
grep -qx -- 'diff --git a/src/wlserver.cpp b/src/wlserver.cpp' "$SPI_PATCH" ||
    fail 'SPI touch patch no longer touches src/wlserver.cpp'
assert_eq "$(grep -c '^+++' "$SPI_PATCH")" 1 'SPI touch patch changes one file'

# The heuristic must learn spi while keeping the i2c and usb branches intact,
# so an unrotated touch can only come back if the association itself regresses.
added=$(grep '^+' "$SPI_PATCH" | grep -c 'subsystem, "spi"')
assert_eq "$added" 1 'the spi bus is added to the connector heuristic'
for bus in i2c usb; do
    grep -q -- "subsystem, \"$bus\"" "$SPI_PATCH" ||
        fail "SPI touch patch dropped the $bus branch"
done

# The angle must keep coming from the connector gamescope selected. A hardcoded
# rotation here would fight KWin in the desktop and break other panels.
angles=$(grep '^+' "$SPI_PATCH" | grep -E 'wlserver_transform|270|ROTATE_' | grep -cv '^\+\+\+')
assert_eq "$angles" 0 'the patch hardcodes no rotation angle'

# --- patches/ and its record agree ------------------------------------------
# A patch that is not in PATCHES.md (or a record for a file that is gone) means
# the shipped build and the documented build have drifted apart.
mapfile -t files < <(find "$GS_PATCH_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.patch' \
    -printf '%f\n' | sort -V)
((${#files[@]} > 0)) || fail 'no gamescope patches found'
mapfile -t doc < <(grep -o '^- `patches/[0-9]\{4\}[^`]*\.patch`$' "$GS_DOC" | sed 's/^- `patches\///; s/`$//')
assert_eq "${#doc[@]}" "${#files[@]}" 'PATCHES.md lists every gamescope patch'
for patch in "${files[@]}"; do
    printf '%s\n' "${doc[@]}" | grep -qx -- "$patch" ||
        fail "PATCHES.md does not record $patch"
done
assert_eq "$(printf '%s\n' "${files[@]}" | cut -c1-4 | sort -u | wc -l)" "${#files[@]}" \
    'gamescope patch numbers are unique'

# --- no libinput rotation matrix in the gaming session ----------------------
# The desktop reaches landscape through KWin (Rotated270) with no calibration
# matrix, so a matrix here would rotate twice in Plasma. Only the TB323FU
# virtual NVT input may carry one, and it is gated on that board's compatible.
grep -q 'LIBINPUT_CALIBRATION_MATRIX' "$STEAM_SESSION" &&
    fail 'the Steam session reintroduced a libinput calibration matrix'
matrix_rules=$(grep -rl 'LIBINPUT_CALIBRATION_MATRIX' "$RULES_DIR" 2>/dev/null |
    xargs -r -n1 basename | sort | paste -sd, -)
assert_eq "$matrix_rules" '99-armada-tb323fu-virtual-touch.rules' \
    'only the TB323FU virtual touch rule calibrates through libinput'

# The Gen2 profile still hands the gaming session an orientation of its own,
# which is the other half of the pairing actually being applied.
grep -q '^ARMADA_GAMESCOPE_ORIENTATION=right$' "$PROFILE" ||
    fail 'tb320fc profile lost ARMADA_GAMESCOPE_ORIENTATION'
grep -q "^ARMADA_PRIMARY_TOUCHSCREEN='NT36523N Capacitive Touchscreen'$" "$PROFILE" ||
    fail 'tb320fc profile does not name the touchscreen the kernel registers'

printf 'gamescope spi touchscreen association checks passed\n'