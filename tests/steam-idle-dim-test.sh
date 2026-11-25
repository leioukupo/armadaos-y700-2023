#!/usr/bin/env bash
# Steam's idle backlight dim, pinned per device (Legion Y700 Gen2).
#
# Steam dims the lamp to ~3 % of its sysfs range after IdleBacklightDim*Seconds with no
# input: 61/2047 on the Gen2's ktz8866, which reads as a switched-off tablet with only
# the performance overlay still lit. The gaming session pins the timers in the user's
# config.vdf before Steam reads it, so a device profile can turn the dim off.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/system_files/usr/libexec/armada/armada-steam-idle-dim"
PROFILE="$ROOT/system_files/usr/lib/armada/devices/lenovo-tb320fc.conf"
DEFAULTS="$ROOT/system_files/usr/lib/armada/devices/defaults.conf"
DEVICE_ENV="$ROOT/system_files/usr/libexec/armada/device-env"
SESSION="$ROOT/system_files/usr/share/gamescope-session-plus/sessions.d/steam"
for f in "$HELPER" "$PROFILE" "$DEFAULTS" "$DEVICE_ENV" "$SESSION"; do
    [[ -r "$f" ]] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 1; }
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok   %s\n' "$1"; }
PYTHON="${PYTHON:-python3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Wiring: the profile sets it, defaults.conf declares it, device-env exports it, and
# the gaming session runs the helper under it.
grep -q '^ARMADA_STEAM_IDLE_DIM_SECONDS=0$' "$PROFILE" \
    || fail 'tb320fc profile lost ARMADA_STEAM_IDLE_DIM_SECONDS'
grep -q '^ARMADA_STEAM_IDLE_DIM_SECONDS=$' "$DEFAULTS" \
    || fail 'defaults.conf lost the ARMADA_STEAM_IDLE_DIM_SECONDS default'
grep -q '^    ARMADA_STEAM_IDLE_DIM_SECONDS$' "$DEVICE_ENV" \
    || fail 'device-env does not export ARMADA_STEAM_IDLE_DIM_SECONDS'
grep -qF -- 'if [[ -n "${ARMADA_STEAM_IDLE_DIM_SECONDS:-}" ]]; then' "$SESSION" \
    || fail 'the gaming session never pins the idle dim'
grep -qF -- 'armada-steam-idle-dim' "$SESSION" \
    || fail 'the gaming session does not name the helper'
ok 'profile, default, export and session wiring'

fixture() {
    cat >"$1" <<'VDF'
"InstallConfigStore"
{
	"Software"
	{
		"total"
		{
			"user47"
			{
				"CompatToolMapping"
				{
					"0"
					{
						"name"		"proton-experimental-arm64"
					}
				}
				"System"
				{
					"IdleBacklightDimBatterySeconds"		"900"
					"IdleBacklightDimACSeconds"		"0"
					"DisplayBrightness"		"0.823878228664398193"
				}
				"LastConfigstoreUploadTime"		"1795509689"
			}
		}
	}
	"System"
	{
		"BigPictureStreamingResolution"		"1600x2560"
	}
	"SDL_GamepadBind"		"03000000de280000ff11000001000000,Steam Virtual Gamepad,dpdown:h0.4{not a brace}"
}
VDF
}

run_helper() {
    env ARMADA_STEAM_CONFIG_VDF="$1" ARMADA_STEAM_IDLE_DIM_SECONDS="$2" "$PYTHON" "$HELPER"
}

digest() { "$PYTHON" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# 1. The entries Steam already wrote get pinned to the profile value.
vdf="$WORK/config.vdf"
fixture "$vdf"
chmod 0755 "$vdf"
run_helper "$vdf" 0 || fail 'helper refused a fixture with both keys present'
grep -q '"IdleBacklightDimBatterySeconds"[[:space:]]*"0"' "$vdf" || fail 'the battery timer was not pinned'
grep -q '"IdleBacklightDimACSeconds"[[:space:]]*"0"' "$vdf" || fail 'the AC timer was not pinned'
grep -q '"DisplayBrightness"[[:space:]]*"0.823878228664398193"' "$vdf" || fail 'the user brightness was not left alone'
grep -qF -- '{not a brace}' "$vdf" || fail 'a value containing braces was mangled'
[[ "$(grep -cE '^[[:space:]]+"System"$' "$vdf")" == "2" ]] || fail 'the System sections changed shape'
[[ "$(stat -c %a "$vdf")" == "755" ]] || fail 'the config file mode changed'
[[ -e "$vdf.armada-tmp" ]] && fail 'a temp file was left behind'
ok 'both idle-dim timers are pinned and the mode is kept'

# 2. Re-running changes nothing, so later sessions stay quiet.
before="$(digest "$vdf")"
run_helper "$vdf" 0 || fail 'helper was not safe to re-run'
[[ "$before" == "$(digest "$vdf")" ]] || fail 'the second run rewrote an already pinned config'
ok 'a second session leaves the config byte identical'

# 3. A Steam that never wrote the keys gets them in the top-level System section.
bare="$WORK/bare.vdf"
grep -v 'IdleBacklightDim' "$vdf" >"$bare"
run_helper "$bare" 0 || fail 'helper could not insert the missing keys'
grep -q '"IdleBacklightDimBatterySeconds"[[:space:]]*"0"' "$bare" || fail 'battery timer not inserted'
grep -q '"IdleBacklightDimACSeconds"[[:space:]]*"0"' "$bare" || fail 'AC timer not inserted'
inserted_at="$(grep -n 'IdleBacklightDimBatterySeconds' "$bare" | cut -d: -f1)"
local_entry=$'^\t\t"IdleBacklightDimBatterySeconds"\t\t"0"$'
local_entry2=$'^\t\t"IdleBacklightDimACSeconds"\t\t"0"$'
grep -qE "$local_entry" "$bare" \
    || fail "the inserted battery timer did not land in the local System section (line $inserted_at)"
grep -qE "$local_entry2" "$bare" \
    || fail 'the inserted AC timer did not land in the local System section'
open=$(grep -c '^{$' "$bare"); closed=$(grep -c '^}$' "$bare")
(( open == closed )) || fail 'the rewritten vdf brace counts diverged'
run_helper "$bare" 0 || fail 'the insert run was not repeatable'
ok 'missing timers are inserted into the local System section'

# 4. No device policy means no write at all.
plain="$WORK/plain.vdf"
fixture "$plain"
untouched="$(digest "$plain")"
run_helper "$plain" "" || fail 'an empty second count must be a no-op, not an error'
env -u ARMADA_STEAM_IDLE_DIM_SECONDS ARMADA_STEAM_CONFIG_VDF="$plain" "$PYTHON" "$HELPER" \
    || fail 'an unset second count must be a no-op'
[[ "$untouched" == "$(digest "$plain")" ]] || fail 'an empty or unset policy still rewrote the config'
ok 'devices without a policy leave Steam settings untouched'

# 5. A broken policy value is refused instead of silently rewriting Steam's config.
if run_helper "$plain" soon; then
    fail 'a non-numeric second count was accepted'
fi
[[ "$untouched" == "$(digest "$plain")" ]] || fail 'a refused value still rewrote the config'
ok 'a non-numeric second count is refused'

# 6. Before Steam has written a config there is nothing to pin, and that is not an error.
if run_helper "$WORK/absent.vdf" 0; then
    ok 'a missing config.vdf is tolerated'
else
    fail 'a missing config.vdf became an error'
fi
[[ -e "$WORK/absent.vdf" ]] && fail 'a missing config.vdf was created'

printf 'steam idle backlight dim checks passed\n'
