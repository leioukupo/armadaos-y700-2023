#!/usr/bin/env bash
set -euo pipefail

# Focused test for the TB322FC-only WirePlumber Iris camera-probe
# workaround installed by device-quirks. Runs the REAL device-quirks against a
# stub device-env and tmp paths; no host state, device, or service is touched.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_QUIRKS="$ROOT/system_files/usr/libexec/armada/device-quirks"
RULE_SRC="$ROOT/system_files/usr/lib/armada/wireplumber/lenovo-tb322fc-iris.conf"
SPEAKER_RULE_SRC="$ROOT/system_files/usr/lib/armada/wireplumber/lenovo-tb320fc-speakers.conf"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'device-quirks audio test failed: %s\n' "$*" >&2
    exit 1
}

bash -n "$DEVICE_QUIRKS" || fail "device-quirks is not valid bash"

# Guard the static rule itself: it must target the exact Iris bus path and
# disable only that device.
grep -q 'device.bus-path = "platform-aa00000.video-codec"' "$RULE_SRC" ||
    fail "rule does not match the exact Iris bus path"
grep -q 'device.disabled = true' "$RULE_SRC" ||
    fail "rule does not disable the device"

# The TB320FC speaker drop-in must only stop the idle suspend, and only for this card.
grep -q 'session.suspend-timeout-seconds = 0' "$SPEAKER_RULE_SRC" ||
    fail "speaker rule does not disable the idle suspend"
grep -q 'alsa.card_name = "Lenovo-Y700"' "$SPEAKER_RULE_SRC" ||
    fail "speaker rule is not scoped to the TB320FC sound card"

# Stub device-env mirroring the real one's contract: print shell assignments
# that device-quirks eval's. $1 is the board id to report.
write_device_env() {
    local id="$1"
    cat >"$WORK/device-env" <<EOF
#!/usr/bin/env bash
printf 'ARMADA_DEVICE_ID=%q\n' '$id'
printf 'ARMADA_SUSPEND_MODE=%q\n' 'fake'
EOF
    chmod +x "$WORK/device-env"
}

# Run the real script with a stubbed device-env and tmp paths. The independent
# sleep / NetworkManager quirks are redirected into WORK too; the ignore-sleep
# file they touch proves the script still runs to completion past the Iris
# install.
run_quirks() {
    local rule="$1" confdir="$2" id="$3" speaker_rule="${4:-$SPEAKER_RULE_SRC}"
    write_device_env "$id"
    env ARMADA_DEVICE_ENV="$WORK/device-env" \
        ARMADA_IRIS_V4L2_RULE="$rule" \
        ARMADA_TB320FC_SPEAKER_RULE="$speaker_rule" \
        ARMADA_WIREPLUMBER_CONFIG_DIR="$confdir" \
        ARMADA_MEM_SLEEP_PATH="$WORK/mem_sleep" \
        ARMADA_SLEEP_CONFIG="$WORK/sleep.conf" \
        ARMADA_NM_IGNORE_SLEEP="$WORK/ignore-sleep" \
        bash "$DEVICE_QUIRKS"
}

# --- TB322FC installs the exact rule; repeat run is idempotent ---------------
confdir="$WORK/wp"
dest="$confdir/90-armada-tb322fc-iris.conf"

run_quirks "$RULE_SRC" "$confdir" lenovo-tb322fc

[[ -f "$dest" ]] || fail "TB322FC did not install the Iris rule"
cmp -s "$RULE_SRC" "$dest" || fail "installed rule does not match the source bytes"
[[ "$(stat -c '%a' "$dest")" == 644 ]] || fail "installed rule mode is not 0644"
[[ "$(stat -c '%a' "$confdir")" == 755 ]] || fail "config dir mode is not 0755"

before="$(stat -c '%i %Y' "$dest")"

# An unrelated drop-in must survive untouched on every run.
printf 'monitor.alsa.rules = []\n' >"$confdir/99-armada-other.conf"
other_before="$(stat -c '%i %Y' "$confdir/99-armada-other.conf")"

run_quirks "$RULE_SRC" "$confdir" lenovo-tb322fc

[[ "$(stat -c '%i %Y' "$dest")" == "$before" ]] ||
    fail "repeat install rewrote the rule (inode/mtime changed)"
[[ "$(stat -c '%i %Y' "$confdir/99-armada-other.conf")" == "$other_before" ]] ||
    fail "repeat run touched an unrelated drop-in"
cmp -s <(printf 'monitor.alsa.rules = []\n') "$confdir/99-armada-other.conf" ||
    fail "unrelated drop-in content changed"
[[ ! -e "$confdir/91-armada-tb320fc-speakers.conf" ]] ||
    fail "TB322FC also installed the TB320FC speaker rule"

# --- TB320FC installs the speaker keep-alive rule; repeat run is idempotent --
confdir="$WORK/wp320"
dest="$confdir/91-armada-tb320fc-speakers.conf"

run_quirks "$RULE_SRC" "$confdir" lenovo-tb320fc

[[ -f "$dest" ]] || fail "TB320FC did not install the speaker rule"
cmp -s "$SPEAKER_RULE_SRC" "$dest" ||
    fail "installed speaker rule does not match the source bytes"
[[ "$(stat -c '%a' "$dest")" == 644 ]] || fail "speaker rule mode is not 0644"
[[ ! -e "$confdir/90-armada-tb322fc-iris.conf" ]] ||
    fail "TB320FC also installed the TB322FC Iris rule"

before="$(stat -c '%i %Y' "$dest")"
run_quirks "$RULE_SRC" "$confdir" lenovo-tb320fc
[[ "$(stat -c '%i %Y' "$dest")" == "$before" ]] ||
    fail "repeat install rewrote the speaker rule (inode/mtime changed)"

# --- Non-matching or empty board ids install nothing ------------------------
confdir="$WORK/noinstall"
for id in lenovo-tb323fu retroid-pocket-5 ""; do
    rm -rf "$confdir"
    run_quirks "$RULE_SRC" "$confdir" "$id"
    [[ ! -e "$confdir/90-armada-tb322fc-iris.conf" ]] ||
        fail "board id '$id' installed the Iris rule"
    [[ ! -e "$confdir/91-armada-tb320fc-speakers.conf" ]] ||
        fail "board id '$id' installed the TB320FC speaker rule"
done

# --- Missing source is diagnostic, not fatal --------------------------------
confdir="$WORK/missing-src"
rm -rf "$confdir" "$WORK/ignore-sleep"
if ! run_quirks "$WORK/absent-rule.conf" "$confdir" lenovo-tb322fc 2>"$WORK/missing.log"; then
    fail "missing rule source aborted device-quirks"
fi
grep -q 'not readable, skipping TB322FC' "$WORK/missing.log" ||
    fail "missing rule source produced no diagnostic"
[[ ! -e "$confdir/90-armada-tb322fc-iris.conf" ]] ||
    fail "missing rule source still installed a rule"
[[ -e "$WORK/ignore-sleep" ]] ||
    fail "device-quirks did not run past a missing rule source"

# --- Failed install is diagnostic, not fatal --------------------------------
printf 'not a directory\n' >"$WORK/blocker"
confdir="$WORK/blocker/wp"
rm -f "$WORK/ignore-sleep"
if ! run_quirks "$RULE_SRC" "$confdir" lenovo-tb322fc 2>"$WORK/blocked.log"; then
    fail "failed install aborted device-quirks"
fi
grep -q 'failed to create' "$WORK/blocked.log" ||
    fail "failed install produced no diagnostic"
[[ -e "$WORK/ignore-sleep" ]] ||
    fail "device-quirks did not run past a failed install"

printf 'device-quirks audio test passed\n'
