#!/usr/bin/env bash
#
# TB320FC /usr replay contract.
#
# An ostree deployment accepts in-place writes to /usr and they survive a reboot, but a
# rollback or any update that composes a new deployment comes back out of the image and
# loses them. system_files/usr/libexec/tb320fc/usr-overlay replays board-side fixes that
# are staged in the stateroot var. This test drives the real helper against a fake root
# in a temp dir: no device, systemd or mount namespace is involved.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/system_files/usr/libexec/tb320fc/usr-overlay"
UNIT="$ROOT/system_files/usr/lib/systemd/system/tb320fc-usr-overlay.service"

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

# ---- build contracts: the image has to carry both halves of the mechanism ----
[ -x "$HELPER" ] || [ -f "$HELPER" ] || fail "missing helper $HELPER"
check "helper is POSIX sh" grep -qx '#!/bin/sh' "$HELPER"
check "helper passes sh -n" sh -n "$HELPER"
check "unit names the helper" grep -q "ExecStart=/usr/libexec/tb320fc/usr-overlay" "$UNIT"
check "unit runs before the helpers it can replace" grep -q 'Before=.*tb320fc-modules-tree.service' "$UNIT"
check "unit is wanted at sysinit" grep -q 'WantedBy=sysinit.target' "$UNIT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stage="$work/var/usrlocal/lib/tb320fc-usroverlay/files"
fake="$work/root"
mkdir -p "$stage/usr/lib/armada" "$stage/usr/libexec/tb320fc"
mkdir -p "$fake/usr/lib/armada"

printf 'panel code v2\n' > "$stage/usr/lib/armada/armada_os.py"
printf 'unchanged content\n' > "$stage/usr/lib/armada/armada_tools.py"
printf '#!/bin/sh\nhelper v2\n' > "$stage/usr/libexec/tb320fc/modules-tree"
printf 'image copy\n' > "$fake/usr/lib/armada/armada_os.py"
printf 'unchanged content\n' > "$fake/usr/lib/armada/armada_tools.py"

run_helper() {
    TB320FC_USROVERLAY_SRC="$stage" TB320FC_USROVERLAY_ROOT="$fake" sh "$HELPER"
}

out="$(run_helper)"
printf '%s\n' "$out"
check "first pass replaces and creates two files" grep -q 'applied=2 kept=1' <<<"$out"
check "stale deployment copy was replaced" grep -qx 'panel code v2' "$fake/usr/lib/armada/armada_os.py"
check "missing helper was created" test -f "$fake/usr/libexec/tb320fc/modules-tree"
check "identical file was left alone" grep -qx 'unchanged content' "$fake/usr/lib/armada/armada_tools.py"
out="$(run_helper)"
check "second pass is a no-op" grep -q 'applied=0 kept=3' <<<"$out"

# A newer image copy is still replayed, which is why the kill switch exists.
printf 'image ships the fix now\n' > "$fake/usr/lib/armada/armada_tools.py"
out="$(run_helper)"
check "drift is reported as applied" grep -q 'applied=1 kept=2' <<<"$out"

: > "$work/var/usrlocal/lib/tb320fc-usroverlay/disabled"
out="$(run_helper)"
check "kill switch skips the replay" grep -q 'skip disabled' <<<"$out"
rm -f "$work/var/usrlocal/lib/tb320fc-usroverlay/disabled"

out="$(TB320FC_USROVERLAY_SRC="$work/absent" TB320FC_USROVERLAY_ROOT="$fake" sh "$HELPER")"
check "no staged content is a clean skip" grep -q 'ok skip stage-missing' <<<"$out"

# ---- modes: a stage that lost the exec bit must not hand systemd a dead ExecStart ----
# PROGRESS.md A185: the push tarball was built on Windows, so every staged helper landed
# in /usr as 666 and the audio unit would have failed the next boot with 203/EXEC.  This
# runs against its own stage/root so the counts above stay meaningful.
stage2="$work/stage2"
fake2="$work/fake2"
mkdir -p "$stage2/usr/libexec/tb320fc" "$stage2/usr/lib/armada"
mkdir -p "$fake2/usr/libexec/tb320fc" "$fake2/usr/lib/armada"
printf 'helper code\n' > "$stage2/usr/libexec/tb320fc/audio"
printf 'same helper\n' > "$stage2/usr/libexec/tb320fc/touch-watch"
printf 'same helper\n' > "$fake2/usr/libexec/tb320fc/touch-watch"
mkdir -p "$stage2/usr/lib/systemd/unit.d" "$fake2/usr/lib/systemd/unit.d"
printf 'old unit\n' > "$stage2/usr/lib/systemd/unit.d/override.conf"
printf 'old unit\n' > "$fake2/usr/lib/systemd/unit.d/override.conf"
chmod 644 "$stage2/usr/libexec/tb320fc/audio" "$stage2/usr/libexec/tb320fc/touch-watch"
chmod 644 "$fake2/usr/libexec/tb320fc/touch-watch" "$fake2/usr/lib/systemd/unit.d/override.conf"
chmod 600 "$fake2/usr/lib/systemd/unit.d/override.conf"

run_helper2() {
    TB320FC_USROVERLAY_SRC="$stage2" TB320FC_USROVERLAY_ROOT="$fake2" sh "$HELPER"
}
out="$(run_helper2)"
printf '%s\n' "$out"
check "a new staged helper is executable" test -x "$fake2/usr/libexec/tb320fc/audio"
check "an identical helper that lost its exec bit is repaired" test -x "$fake2/usr/libexec/tb320fc/touch-watch"
check "a helper that drifted to 777 converges on 755" test "$(stat -c %a "$fake2/usr/libexec/tb320fc/audio")" -eq 755
check "a staged text file converges on 644 whatever it was" test "$(stat -c %a "$fake2/usr/lib/systemd/unit.d/override.conf")" -eq 644

chmod 777 "$fake2/usr/libexec/tb320fc/audio"
out="$(run_helper2)"
check "mode repair is idempotent" grep -q 'applied=0 kept=3' <<<"$out"
check "the drift is normalised" test "$(stat -c %a "$fake2/usr/libexec/tb320fc/audio")" -eq 755

# ---- the replay must not re-interpret itself when the stage carries a newer copy ----
# On the tablet the stage grew a newer usr-overlay, the running copy cp -a'd over itself,
# and the shell kept reading the replaced file at a stale offset:
# "line 49: ission: command not found" half way through the loop.
selfroot="$work/self"
selfstage="$work/selfstage"
mkdir -p "$selfroot/usr/libexec/tb320fc" "$selfroot/usr/lib/armada"
mkdir -p "$selfstage/usr/libexec/tb320fc" "$selfstage/usr/lib/armada"
cp "$HELPER" "$selfroot/usr/libexec/tb320fc/usr-overlay"
printf '# this copy is behind the stage\n' >> "$selfroot/usr/libexec/tb320fc/usr-overlay"
cp "$HELPER" "$selfstage/usr/libexec/tb320fc/usr-overlay"
printf 'stale panel code\n' > "$selfroot/usr/lib/armada/armada_os.py"
printf 'fresh panel code\n' > "$selfstage/usr/lib/armada/armada_os.py"
run_self() {
    TB320FC_USROVERLAY_SRC="$selfstage" TB320FC_USROVERLAY_ROOT="$selfroot" \
        sh "$selfroot/usr/libexec/tb320fc/usr-overlay"
}
out="$(run_self)"
printf '%s\n' "$out"
check "a newer staged copy restarts the replay cleanly" grep -q 'restart self-updated' <<<"$out"
check "the restarted pass still replays the rest" grep -q 'applied=1 kept=' <<<"$out"
check "the deployment copy was refreshed" grep -qx 'fresh panel code' "$selfroot/usr/lib/armada/armada_os.py"
check "the helper on disk now matches the stage" cmp -s "$selfroot/usr/libexec/tb320fc/usr-overlay" "$HELPER"
out="$(run_self)"
if grep -q 'restart self-updated' <<<"$out"; then
    fail "the self-update loops"
else
    printf 'ok no restart once the copies match\n'
fi

printf 'ALL OK\n'
