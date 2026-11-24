#!/usr/bin/env bash
# Steam-mode orientation and readiness window for the Legion Y700 Gen2.
#
# The Gen2 panel is scanned out portrait and KWin rotates it for the desktop, so
# the gaming session has to be handed an orientation of its own; and Gamescope
# takes fifty seconds to report its displays there, which the launcher default
# of fifteen seconds turns into "gamescope failed".

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STEAM_SESSION="$ROOT/system_files/usr/share/gamescope-session-plus/sessions.d/steam"
PROFILE="$ROOT/system_files/usr/lib/armada/devices/lenovo-tb320fc.conf"
DEFAULTS="$ROOT/system_files/usr/lib/armada/devices/defaults.conf"
DEVICE_ENV="$ROOT/system_files/usr/libexec/armada/device-env"
PATCH="$ROOT/packages/gamescope-session/patches/0010-configurable-startup-socket-timeout.patch"
for f in "$STEAM_SESSION" "$PROFILE" "$DEFAULTS" "$DEVICE_ENV" "$PATCH"; do
    [[ -r "$f" ]] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 1; }
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s: got "%s" want "%s"\n' "$3" "$1" "$2" >&2
        exit 1
    fi
    printf 'ok   %s\n' "$3"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASH_BIN="$(command -v bash)"

# The launcher sources this file before it builds the Gamescope command line, so
# only the part before the first sourced helper is plain shell we can execute.
grep -Fqx -- 'source /usr/lib/armada/storage-lib' "$STEAM_SESSION" \
    || fail 'Steam session is missing expected storage-lib source line'
preamble="$WORK/steam-preamble.sh"
awk '/^source \/usr\/lib\/armada\/storage-lib/ { exit } { print }' "$STEAM_SESSION" > "$preamble"
[[ -s "$preamble" ]] || fail 'extracted Steam preamble is empty'

session_value() {
    local device="$1" orientation="${2-}" panel="${3-}" gamescope="${4-}"
    local -a cmd=(env -i "ARMADA_DEVICE_ID=$device")

    [[ -z "$orientation" ]] || cmd+=("ORIENTATION=$orientation")
    [[ -z "$panel" ]] || cmd+=("ARMADA_PANEL_ORIENTATION=$panel")
    [[ -z "$gamescope" ]] || cmd+=("ARMADA_GAMESCOPE_ORIENTATION=$gamescope")
    "${cmd[@]}" "$BASH_BIN" --noprofile --norc -c \
        "source \"\$1\"; printf '%s' \"\${$5-<unset>}\"" _ "$preamble"
}

assert_eq "$(session_value lenovo-tb323fu '' '' right ORIENTATION)" right \
    'TB323FU keeps its panel-rotation fallback'
assert_eq "$(session_value lenovo-tb323fu left '' right ORIENTATION)" left \
    'an explicit ORIENTATION still wins on TB323FU'
assert_eq "$(session_value lenovo-tb323fu '' normal '' ORIENTATION)" normal \
    'TB323FU falls back to ARMADA_PANEL_ORIENTATION'
assert_eq "$(session_value lenovo-tb320fc '' normal right ORIENTATION)" right \
    'the gamescope orientation drives the gaming session'
assert_eq "$(session_value lenovo-tb320fc '' normal '' ORIENTATION)" '<unset>' \
    'no gamescope orientation leaves the session unrotated'
assert_eq "$(session_value lenovo-tb320fc left normal right ORIENTATION)" left \
    'an explicit ORIENTATION wins over the profile'
assert_eq "$(session_value unknown-device '' normal right ORIENTATION)" right \
    'the gamescope orientation is device independent'

# Wiring: the profile sets it, defaults.conf declares it, device-env exports it.
grep -q '^ARMADA_GAMESCOPE_ORIENTATION=right$' "$PROFILE" \
    || fail 'tb320fc profile lost ARMADA_GAMESCOPE_ORIENTATION'
grep -q '^ARMADA_GAMESCOPE_ORIENTATION=$' "$DEFAULTS" \
    || fail 'defaults.conf lost the ARMADA_GAMESCOPE_ORIENTATION default'
grep -q '^    ARMADA_GAMESCOPE_ORIENTATION$' "$DEVICE_ENV" \
    || fail 'device-env does not export ARMADA_GAMESCOPE_ORIENTATION'
grep -q '^ARMADA_GAMESCOPE_STARTUP_TIMEOUT=90$' "$PROFILE" \
    || fail 'tb320fc profile lost ARMADA_GAMESCOPE_STARTUP_TIMEOUT'
grep -q '^ARMADA_GAMESCOPE_STARTUP_TIMEOUT=$' "$DEFAULTS" \
    || fail 'defaults.conf lost the ARMADA_GAMESCOPE_STARTUP_TIMEOUT default'
grep -q '^    ARMADA_GAMESCOPE_STARTUP_TIMEOUT$' "$DEVICE_ENV" \
    || fail 'device-env does not export ARMADA_GAMESCOPE_STARTUP_TIMEOUT'
printf 'ok   profile, default and export wiring\n'

# The readiness window lives in the launcher package patch, not in system_files,
# so exercise the mapping it adds and keep its fallback visible.
grep -qF -- '+if read -r -t "${GAMESCOPE_STARTUP_TIMEOUT:-15}"' "$PATCH" \
    || fail 'launcher no longer falls back to fifteen seconds'
mapping="$WORK/mapping.sh"
sed -n '/if \[ -n "${ARMADA_GAMESCOPE_STARTUP_TIMEOUT:-}" \]; then$/,/^[- ]fi$/p' "$PATCH" |
    sed 's/^[-+]//' > "$mapping"
[[ -s "$mapping" ]] || fail 'launcher patch lost the startup timeout mapping'
assert_eq "$(env -i ARMADA_GAMESCOPE_STARTUP_TIMEOUT=90 "$BASH_BIN" --noprofile --norc -c \
    'source "$1"; printf "%s" "${GAMESCOPE_STARTUP_TIMEOUT-<unset>}"' _ "$mapping")" 90 \
    'the profile value becomes the readiness window'
assert_eq "$(env -i "$BASH_BIN" --noprofile --norc -c \
    'source "$1"; printf "%s" "${GAMESCOPE_STARTUP_TIMEOUT-<unset>}"' _ "$mapping")" '<unset>' \
    'devices without a value keep the launcher default'

printf 'steam session orientation and readiness checks passed\n'
