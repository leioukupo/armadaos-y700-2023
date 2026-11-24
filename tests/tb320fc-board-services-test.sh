#!/usr/bin/env bash
#
# TB320FC board-service contract (PROGRESS.md A185).
#
# Two failures on the real tablet both came from how the helpers find each other and who
# is allowed to write the amplifier controls:
#   * an image that carries audio/power but no modload, or a fix replayed into
#     /usr/local/libexec instead of /usr/libexec, made the module chain die on a literal
#     "/usr/libexec/tb320fc/modload: No such file or directory" while the route still
#     ran - the journal looked healthy and one speaker was silent.
#   * the A-series boot payload re-arms y700-audio.service / y700-power.service in /etc
#     every boot, so a second writer raced the CS35L45 kcontrols.
# This test drives the real scripts against fakes in a temp dir: no device, systemd or
# root is involved.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXEC="$ROOT/system_files/usr/libexec/tb320fc"
UNITS="$ROOT/system_files/usr/lib/systemd/system"
USERUNITS="$ROOT/system_files/usr/lib/systemd/user"
BUILD="$ROOT/build_files/40-vendor-system-files.sh"
PUSH="$ROOT/devices/lenovo-tb320fc/usr-overlay/push.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

check() {
    local label="$1"
    shift
    if "$@"; then
        printf 'ok %s\n' "$label"
    else
        fail "$label"
    fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- every helper is POSIX sh and resolves siblings instead of hard-coding them ----
for h in audio power input modload legacy-off wifi wifi-mac wifi-mac-sync touch-watch touch-revive; do
    [ -f "$EXEC/$h" ] || fail "missing helper $EXEC/$h"
    check "$h passes sh -n" sh -n "$EXEC/$h"
done
for h in audio power input legacy-off wifi touch-watch; do
    check "$h defines the sibling resolver" grep -q 'tb320fc_exec()' "$EXEC/$h"
    check "$h looks next to itself first" grep -q '"$(dirname "$0")" /usr/libexec/tb320fc /usr/local/libexec/tb320fc' "$EXEC/$h"
    if grep -Eq '^[[:space:]]*/usr/libexec/tb320fc/(modload|board-check)' "$EXEC/$h"; then
        fail "$h still calls a hard-coded sibling path"
    fi
done
printf 'ok no helper hard-codes a sibling path\n'

# ---- units: one owner per job, takeover ordered before the units it protects ----
for u in tb320fc-audio tb320fc-power tb320fc-input tb320fc-modules-tree tb320fc-usr-overlay tb320fc-legacy-off; do
    [ -f "$UNITS/$u.service" ] || fail "missing unit $UNITS/$u.service"
done
check "legacy-off runs the takeover helper" grep -q 'ExecStart=/usr/libexec/tb320fc/legacy-off' "$UNITS/tb320fc-legacy-off.service"
check "legacy-off precedes the audio chain" grep -q 'Before=.*tb320fc-audio.service' "$UNITS/tb320fc-legacy-off.service"
check "legacy-off precedes the power chain" grep -q 'Before=.*tb320fc-power.service' "$UNITS/tb320fc-legacy-off.service"
check "legacy-off precedes multi-user (payload units live there)" grep -q 'Before=.*multi-user.target' "$UNITS/tb320fc-legacy-off.service"
check "legacy-off is armed at sysinit" grep -q 'WantedBy=sysinit.target' "$UNITS/tb320fc-legacy-off.service"
check "audio is the only route writer for its card" grep -q '^passes=' "$EXEC/audio"
# The arm-at-boot half is not enough on its own: the ADSP graph and both
# amplifiers are rebuilt every time the session audio stack starts, and an
# armed-but-not-re-armed path is silent while every kcontrol reads like the
# working one (PROGRESS.md A184, A189). So the session re-arms through gate mode.
check "audio takes a boot/gate mode" grep -q 'MODE=${1:-boot}' "$EXEC/audio"
check "audio rejects an unknown mode" grep -q 'usage: audio \[boot|gate|watch\]' "$EXEC/audio"
check "gate mode has its own poll budget" grep -q '^gate_polls=' "$EXEC/audio"
check "gate mode never reloads the module chain" grep -q '"${MODE}" = boot \] && \[ "${load}" = on ' "$EXEC/audio"
check "gate mode never restarts the ADSP" grep -q '"${MODE}" = boot \] && \[ -z "$(ls /sys/bus/aprbus/devices' "$EXEC/audio"
# The re-arm is only real if the amplifiers actually leave the DAPM power domain:
# DAPM defers the power-down by its PMD delay, so an off/on pair written back to
# back never sends CSPL PAUSE/RESUME and the silent path stays silent (A189 ran
# exactly that no-op and the speakers stayed dead until the gap was added).
check "route has an amplifier power cycle knob" grep -q '^amp_cycle=on$' "$EXEC/audio"
check "route separates AMP off from AMP on" grep -q 'sleep "${amp_off_gap}"' "$EXEC/audio"
check "route counts the powered amplifiers before cycling" grep -q 'amps_powered() {' "$EXEC/audio"
check "route cycles on the first pass only" grep -q 'spkroute "${NC}" "${p}"' "$EXEC/audio"
# A cycle that runs while the PCM is still closed does nothing: UCM powers the
# amplifiers up before q6apm triggers the backend, so they never lock to the TDM
# frame. The re-lock has to follow the stream (A190).
check "audio takes a watch mode" grep -q 'usage: audio \[boot|gate|watch\]' "$EXEC/audio"
check "watch mode tracks the running stream" grep -q '"${st}" = RUNNING ' "$EXEC/audio"
check "watch mode cycles once per stream" grep -q '[ "${NC}/${trig}" != "${seen}" ]' "$EXEC/audio"
check "watch mode never reloads the module chain" grep -q '^watch_polls=' "$EXEC/audio"
# The patched payload driver re-locks the amplifiers from the codec DAI trigger: same
# power sequence, but about 100 ms after the backend starts and with a 200 ms gap
# instead of three seconds. Both userspace paths have to get out of the way then, and
# they read the kernel parameter on every use so the switch works at runtime (A192).
check "audio detects the in-kernel re-lock" grep -q 'kernel_relock() {' "$EXEC/audio"
check "route skips its power cycle for the in-kernel re-lock" grep -q '! kernel_relock &&' "$EXEC/audio"
check "watch skips its cycle for the in-kernel re-lock" grep -q 'skipped, kernel re-locks the amplifiers' "$EXEC/audio"
check "the kernel re-lock patch is kept for the payload build" test -f "$ROOT/devices/lenovo-tb320fc/patches/kernel/0001-cs35l45-relock-amps-after-stream-start.patch"
WATCH="$USERUNITS/tb320fc-speaker-watch.service"
check "watch unit exists" test -f "$WATCH"
check "watch unit runs watch mode" grep -q 'ExecStart=/usr/libexec/tb320fc/audio watch' "$WATCH"
check "watch unit stays resident" grep -q 'Type=simple' "$WATCH"
check "watch unit starts after the audio stack" grep -q 'After=pipewire.service wireplumber.service' "$WATCH"
check "watch unit dies with the audio stack" grep -q 'BindsTo=pipewire.service wireplumber.service' "$WATCH"
check "image enables the watcher globally" grep -Fxq 'systemctl --global enable tb320fc-speaker-watch.service' "$BUILD"
check "push carries the watcher unit" grep -q 'usr/lib/systemd/user/tb320fc-speaker-watch.service' "$PUSH"

GATE="$USERUNITS/tb320fc-speaker-gate.service"
check "session unit exists" test -f "$GATE"
check "session unit runs gate mode" grep -q 'ExecStart=/usr/libexec/tb320fc/audio gate' "$GATE"
check "session unit starts after the audio stack" grep -q 'After=pipewire.service wireplumber.service' "$GATE"
check "session unit is pulled in by the audio stack" grep -q 'WantedBy=pipewire.service wireplumber.service' "$GATE"
check "session unit dies with the audio stack" grep -q 'BindsTo=pipewire.service wireplumber.service' "$GATE"
check "image enables the session unit globally" grep -Fxq 'systemctl --global enable tb320fc-speaker-gate.service' "$BUILD"
for u in tb320fc-modules-tree tb320fc-usr-overlay tb320fc-legacy-off tb320fc-audio tb320fc-power tb320fc-wifi tb320fc-wifi-mac tb320fc-touch tb320fc-input; do
    check "image enables $u.service" grep -Fxq "systemctl enable $u.service" "$BUILD"
done

# ---- the convergence tool: stage, replay, and retire the bring-up leftovers ----
PUSH="$ROOT/devices/lenovo-tb320fc/usr-overlay/push.sh"
[ -f "$PUSH" ] || fail "missing $PUSH"
check "push is POSIX sh" sh -n "$PUSH"
check "push reads only from system_files" grep -q 'cd "$REPO/system_files"' "$PUSH"
check "push writes the stateroot stage" grep -q 'STAGE=/var/usrlocal/lib/tb320fc-usroverlay/files' "$PUSH"
check "push fixes stage modes before anything execs them" grep -q "exec chmod 755" "$PUSH"
check "push normalises staged unit and config modes" grep -q "service. -o -name .*.conf." "$PUSH"
# Everything the remote half references has to be defined inside the heredoc: a local-only
# variable reads as an empty string there, and set -eu then kills the push half way through
# (STALE was referenced but never passed).
remote_body="$(sed -n '/^cat > "$script" <<REMOTE$/,/^REMOTE$/p' "$PUSH")"
for v in STAGE TAR ARM HACKS STALE GLOBAL; do
    check "board half defines $v" grep -Eq "^[[:space:]]*${v}=" <<<"$remote_body"
    check "board half uses $v" grep -Eq "[\\$]\\{?${v}\\}?" <<<"$remote_body"
done
check "push replays the stage into the live deployment" grep -q 'usr/libexec/tb320fc/usr-overlay' "$PUSH"
check "push retires the /usr/local ExecStart drop-ins" grep -q 'tb320fc-audio.service.d /etc/systemd/system/tb320fc-power.service.d' "$PUSH"
check "push retires stale /usr/local helper copies" grep -q "/usr/local/libexec/tb320fc/audio" "$PUSH"
check "push only retires copies that differ from /usr" grep -q "cmp -s .*basename" "$PUSH"
check "push moves the stale /etc unit copies aside" grep -q 'units/\\\$u.etcbak' "$PUSH"
check "push re-arms every board unit after the move" grep -q "systemctl enable" "$PUSH"
check "push carries the session audio unit" grep -q 'usr/lib/systemd/user/tb320fc-speaker-gate.service' "$PUSH"
check "push enables the session unit for the user" grep -q 'systemctl --global enable' "$PUSH"
for u in tb320fc-modules-tree.service tb320fc-usr-overlay.service tb320fc-legacy-off.service tb320fc-input.service; do
    check "push carries $u" grep -q "$u" "$PUSH"
done

for u in y700-audio.service y700-power.service y700-wifi.service y700-touchd.service; do
    check "legacy-off names the payload twin $u" grep -q "$u" "$EXEC/legacy-off"
    check "the shipped conf lists $u too" grep -q "$u" "$ROOT/system_files/etc/tb320fc/legacy-off.conf"
done
check "the wifi helper pins the MAC" grep -q 'ip link set "${I}" address' "$EXEC/wifi"
check "the wifi helper asks wifi-mac" grep -q 'tb320fc_exec wifi-mac resolve' "$EXEC/wifi"
check "the wifi sync unit teaches NetworkManager" grep -q "802-11-wireless.cloned-mac-address" "$EXEC/wifi-mac-sync"
check "the wifi sync unit runs after NetworkManager" grep -q "After=NetworkManager.service" "$UNITS/tb320fc-wifi-mac.service"
check "the wifi bring-up stays before NetworkManager" grep -q "Before=NetworkManager.service" "$UNITS/tb320fc-wifi.service"
check "the wifi helper pins the NetworkManager default as well" grep -q '90-tb320fc-wifi-mac.conf' "$EXEC/wifi"
check "the wifi helper applies that pin from the resolved address" grep -q 'nm_conf "${want_mac}"' "$EXEC/wifi"
check "the wifi helper drops the pin when mac is keep" grep -q 'nm_conf off' "$EXEC/wifi"
check "the sync clears address bindings the way nmcli accepts" grep -q '802-11-wireless.mac-address ""' "$EXEC/wifi-mac-sync"
check "the wifi conf carries mac_nm" grep -q "^mac_nm=on$" "$ROOT/system_files/etc/tb320fc/wifi.conf"
check "the wifi conf turns address bindings off" grep -q "^mac_bind=off$" "$ROOT/system_files/etc/tb320fc/wifi.conf"
check "the wifi conf documents the pin" grep -q "^mac=auto$" "$ROOT/system_files/etc/tb320fc/wifi.conf"
check "the touch watcher resolves touch-revive" grep -q "helper=touch-revive" "$EXEC/touch-watch"
# ---- sibling resolution: own directory wins, and a missing sibling is reported ----
bindir="$work/bin"
mkdir -p "$bindir"
cp "$EXEC/input" "$bindir/input"
printf '#!/bin/sh\nexit 0\n' > "$bindir/board-check"
printf '#!/bin/sh\necho "TOUCHED $*"\n' > "$bindir/modload"
chmod +x "$bindir/board-check" "$bindir/modload"

out="$("$bindir/input" 2>&1)"
printf '%s\n' "$out"
check "modload next to the helper is used" grep -q 'TOUCHED uhid' <<<"$out"

mkdir -p "$work/lonely"
cp "$EXEC/input" "$work/lonely/input"
printf '#!/bin/sh\nexit 0\n' > "$work/lonely/board-check"
chmod +x "$work/lonely/board-check"
out="$("$work/lonely/input" 2>&1)"
check "a missing sibling is named instead of silently skipped" grep -q 'FAIL helper missing helper=modload' <<<"$out"
check "the caller still reports the degradation" grep -q 'WARN uhid unavailable' <<<"$out"

# the board gate has to win before anything is touched
mkdir -p "$work/otherboard"
cp "$EXEC/legacy-off" "$work/otherboard/legacy-off"
printf '#!/bin/sh\nexit 1\n' > "$work/otherboard/board-check"
chmod +x "$work/otherboard/board-check"
out="$("$work/otherboard/legacy-off" 2>&1)"
[ -z "$out" ] || fail "non-TB320FC board produced output: $out"
printf 'ok other boards stay silent\n'

# ---- legacy-off: disable, get the payload file out of the way, then mask ----
fakebin="$work/fakebin"
unitdir="$work/units"
state="$work/state"
log="$work/systemctl.log"
statedir="$work/state-dir"
mkdir -p "$fakebin" "$state" "$statedir" "$unitdir"
# systemd 259 refuses to mask over a unit file that exists, which is exactly the case on
# the tablet: the payload wrote /etc/systemd/system/y700-audio.service this boot.
cat > "$fakebin/systemctl" <<FAKE
#!/bin/sh
state="$state"
unitdir="$unitdir"
log="$log"
unit=""
for a in "\$@"; do case "\$a" in *.service|*.timer) unit="\$a" ;; esac; done
case "\$1" in
    is-enabled)
        if [ -L "\$unitdir/\$unit" ]; then echo masked
        elif [ -e "\$unitdir/\$unit" ]; then echo enabled
        else echo missing; fi
        exit 0
        ;;
    disable) echo "disable \$unit" >> "\$log"; exit 0 ;;
    mask)
        if [ -e "\$unitdir/\$unit" ] && [ ! -L "\$unitdir/\$unit" ]; then
            echo "Failed to mask unit: File '\$unitdir/\$unit' already exists" >&2
            exit 1
        fi
        echo "mask \$unit" >> "\$log"
        ln -s /dev/null "\$unitdir/\$unit"
        exit 0
        ;;
    daemon-reload) echo daemon-reload >> "\$log"; exit 0 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$fakebin/systemctl"
for f in y700-audio.service y700-power.service y700-wifi.service y700-touchd.service; do printf 'payload unit\n' > "$unitdir/$f"; done
printf 'payload unit\n' > "$unitdir/y700-power.service"

mkdir -p "$work/owner"
cp "$EXEC/legacy-off" "$work/owner/legacy-off"
printf '#!/bin/sh\nexit 0\n' > "$work/owner/board-check"
chmod +x "$work/owner/board-check"
run_legacy() {
    PATH="$fakebin:$PATH" TB320FC_LEGACY_STATE_DIR="$statedir" TB320FC_LEGACY_UNIT_DIR="$unitdir" \
        sh "$work/owner/legacy-off"
}

out="$(run_legacy)"
printf '%s\n' "$out"
check "the payload audio unit is masked" grep -q 'masked unit=y700-audio.service was=enabled' <<<"$out"
check "the payload power unit is masked" grep -q 'masked unit=y700-power.service was=enabled' <<<"$out"
check "both are un-armed before masking" grep -qx 'disable y700-audio.service' "$log"
check "reload happens once" test "$(grep -cx 'daemon-reload' "$log")" -eq 1
check "all four are reported" grep -q 'ok masked=4 skipped=0' <<<"$out"
check "audio really is masked now" test -L "$unitdir/y700-audio.service"
check "the payload unit file is kept as a backup" grep -qx 'payload unit' "$statedir/units/y700-audio.service.bak"
check "the backup is named after the unit" test -f "$statedir/units/y700-power.service.bak"

: > "$work/systemctl.log"
out="$(run_legacy)"
check "a second boot changes nothing" grep -q 'ok masked=0 skipped=4' <<<"$out"
check "a second boot calls no systemctl mutation" test ! -s "$work/systemctl.log"

# A payload that re-arms the unit (mask symlink intact, cat > lands in /dev/null) stays masked.
out="$(run_legacy)"
check "masking survives the payload rewriting the unit" grep -q 'ok masked=0 skipped=4' <<<"$out"

: > "$statedir/legacy-off.disabled"
out="$(run_legacy)"
check "kill switch skips the takeover" grep -q 'skip disabled' <<<"$out"

# ---- wifi-mac: the pin has to be deterministic and honour the config value ----
MAC="$EXEC/wifi-mac"
check "wifi-mac passes sh -n" sh -n "$MAC"
m1="$(sh "$MAC")"
m2="$(sh "$MAC")"
check "wifi-mac is deterministic" test "$m1" = "$m2"
check "wifi-mac keeps the vendor prefix" grep -Eq '^00:03:7f:12:[0-9a-f]{2}:[0-9a-f]{2}$' <<<"$m1"
check "wifi-mac resolve keep says keep" test "$(sh "$MAC" resolve keep)" = keep
check "wifi-mac resolve passes an explicit address" test "$(sh "$MAC" resolve 00:11:22:33:44:55)" = 00:11:22:33:44:55
check "wifi-mac resolve lowercases" test "$(sh "$MAC" resolve 00:11:22:33:44:AA)" = 00:11:22:33:44:aa
check "wifi-mac resolve auto derives" test "$(sh "$MAC" resolve auto)" = "$m1"
check "wifi-mac honours an alternative prefix" test "$(TB320FC_MAC_PREFIX=02:11:22:33 sh "$MAC")" = "02:11:22:33${m1#00:03:7f:12}"

# ---- wifi-mac-sync: writes the address into the connections; NM is already up here ----
syncdir="$work/sync"
mkdir -p "$syncdir" "$work/nmstate"
cp "$EXEC/wifi-mac-sync" "$syncdir/wifi-mac-sync"
cp "$EXEC/wifi-mac" "$syncdir/wifi-mac"
printf '#!/bin/sh\nexit 0\n' > "$syncdir/board-check"
chmod +x "$syncdir/board-check"
cat > "$syncdir/nmcli" <<'NMFAKE'
#!/bin/sh
st="$NM_STATE"
if [ "$1" = -t ] && [ "$2" = -f ] && [ "$3" = UUID,TYPE ] && [ "$4" = connection ]; then
    if [ "${NM_DOWN:-}" = yes ]; then echo "error: NetworkManager is not running" >&2; exit 1; fi
    printf 'aa11:802-11-wireless\nbb22:loopback\ncc33:802-11-wireless\n'
    exit 0
fi
if [ "$1" = -g ] && [ "$2" = 802-11-wireless.cloned-mac-address ]; then
    cat "$st/$5" 2>/dev/null || true
    exit 0
fi
if [ "$1" = -g ] && [ "$2" = 802-11-wireless.mac-address ]; then
    cat "$st/$5.bind" 2>/dev/null || true
    exit 0
fi
if [ "$1" = connection ] && [ "$2" = modify ]; then
    # NetworkManager 1.58 rejects "-<setting>.<property>" for a scalar ("value ... is
    # missing"); a scalar is cleared by giving it an empty value. Refuse the dash form here
    # so a helper that reaches for it fails the test instead of silently doing nothing.
    case "$4" in -*) printf 'Error: value for '%s' is missing.\n' "$4" >&2; exit 2 ;; esac
    if [ "$4" = 802-11-wireless.mac-address ]; then
        if [ "$5" = "" ]; then rm -f "$st/$3.bind"; else echo "$5" > "$st/$3.bind"; fi
    else
        echo "$5" > "$st/$3"
    fi
    echo "modify $3 $4" >> "$st/log"
    exit 0
fi
if [ "$1" = device ] && [ "$2" = reapply ]; then
    echo "reapply $3" >> "$st/log"
    exit 0
fi
exit 0
NMFAKE
chmod +x "$syncdir/nmcli"

run_sync() {
    PATH="$syncdir:$PATH" NM_STATE="$work/nmstate" TB320FC_WIFI_CONF="$work/sync.conf" \
        sh "$syncdir/wifi-mac-sync"
}

printf 'mac=auto\nmac_nm=on\n' > "$work/sync.conf"
want="$(sh "$syncdir/wifi-mac")"
out="$(run_sync)"
printf '%s\n' "$out"
check "the sync updates both wifi connections" grep -q 'updated=2' <<<"$out"
check "the sync skips loopback" bash -c "! grep -q 'modify bb22' '$work/nmstate/log'"
check "the sync writes the derived address" grep -q "want=${want}" <<<"$out"
check "the sync logs each connection" test "$(grep -c '^modify ' "$work/nmstate/log")" -eq 2

out="$(run_sync)"
check "a boot that is already correct writes nothing" grep -q 'updated=0' <<<"$out"

# A profile bound with 802-11-wireless.mac-address only matches the device address of the
# boot that created it, so on this chip it guarantees a password prompt on the next boot.
printf '00:03:7F:12:AA:BB\n' > "$work/nmstate/aa11.bind"
printf '00:03:7F:12:CC:DD\n' > "$work/nmstate/cc33.bind"
: > "$work/nmstate/log"
out="$(run_sync)"
printf '%s\n' "$out"
check "the sync clears a per-boot address binding" grep -q 'unbound=2' <<<"$out"
out="$(run_sync)"
check "the second sync has nothing left to clear" grep -q 'unbound=0' <<<"$out"
printf 'mac=auto\nmac_nm=on\nmac_bind=on\n' > "$work/sync.conf"
printf '00:03:7F:12:AA:BB\n' > "$work/nmstate/aa11.bind"
out="$(run_sync)"
check "mac_bind=on leaves the address binding alone" grep -q 'unbound=0' <<<"$out"

printf 'mac=keep\nmac_nm=on\n' > "$work/sync.conf"
out="$(run_sync)"
check "the sync waits for the association before judging" grep -q "DEVICE,STATE device status" "$EXEC/wifi-mac-sync"
check "the sync reports the on-air address" grep -q "on-air=" "$EXEC/wifi-mac-sync"
check "the sync re-applies only when it drifted" grep -q "nmcli device reapply" "$EXEC/wifi-mac-sync"
check "mac=keep skips the sync" grep -q 'skip want=keep' <<<"$out"

printf 'mac=auto\nmac_nm=off\n' > "$work/sync.conf"
out="$(run_sync)"
check "mac_nm=off skips the sync" grep -q 'skip mac_nm=off' <<<"$out"

printf 'mac=auto\nmac_nm=on\n' > "$work/sync.conf"
out="$(NM_DOWN=yes run_sync)"
check "a NetworkManager that never answers is reported, not guessed" grep -q 'FAIL NetworkManager never answered' <<<"$out"
printf 'ALL OK\n'