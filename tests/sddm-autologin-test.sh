#!/usr/bin/env bash
# Covers how the sddm autologin session is chosen: session-control must own the
# file that sddm reads last, and armada-fixups must fold in the legacy names that
# used to pin the session (zz-steamos, and the Y700 bring-up file).

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_CONTROL_SRC="$ROOT/system_files/usr/libexec/armada/session-control"
FIXUPS_SRC="$ROOT/system_files/usr/libexec/armada/armada-fixups"
for f in "$SESSION_CONTROL_SRC" "$FIXUPS_SRC"; do
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
sddm_dir="$WORK/etc/sddm.conf.d"
bin="$WORK/bin"
mkdir -p "$sddm_dir" "$bin"

command -v python3 >/dev/null || fail 'python3 is required'

# Nothing in the test may touch the host: every privileged helper is a stub that
# only records what it was asked to do, and sleep is stubbed so the confirmation
# loop is instant.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SYSTEMCTL_LOG"\n' > "$bin/systemctl"
printf '#!/bin/sh\nexit "${SUDO_EXIT:-1}"\n' > "$bin/sudo"
printf '#!/bin/sh\nexit "${QDBUS_EXIT:-1}"\n' > "$bin/qdbus-qt6"
printf '#!/bin/sh\nif [ "$2" = kwin_wayland ]; then exit "${KWIN_EXIT:-1}"; fi\nexit 1\n' > "$bin/pgrep"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SLEEP_LOG"\n' > "$bin/sleep"
chmod +x "$bin/systemctl" "$bin/sudo" "$bin/qdbus-qt6" "$bin/pgrep" "$bin/sleep"

# logout_plasma only talks to Plasma when the session bus socket exists, so the
# scenarios that need it to be attempted bind a real socket under $WORK.
mkdir -p "$WORK/run/user/1000"
python3 - "$WORK/run/user/1000/bus" <<'PYEOF'
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
PYEOF

printf 'armada_plasma_shell() { printf "mobile\\n"; }\n' > "$WORK/plasma-session-lib"
printf '#!/bin/sh\nprintf "ARMADA_DEFAULT_SESSION=desktop\\n"\n' > "$WORK/device-env"
chmod +x "$WORK/device-env"

session_control="$WORK/session-control"
sed -e "s#/etc/sddm.conf.d#$sddm_dir#g" \
    -e "s#/usr/libexec/armada/device-env#$WORK/device-env#g" \
    -e "s#/run/user#$WORK/run/user#g" \
    "$SESSION_CONTROL_SRC" > "$session_control"
chmod +x "$session_control"

run_session_control() {
    env -i PATH="$bin:/usr/bin:/bin" \
        SYSTEMCTL_LOG="$WORK/systemctl.log" \
        SLEEP_LOG="$WORK/sleep.log" \
        SUDO_EXIT="${SUDO_EXIT:-1}" QDBUS_EXIT="${QDBUS_EXIT:-1}" \
        KWIN_EXIT="${KWIN_EXIT:-1}" \
        ARMADA_PLASMA_SESSION_LIB="$WORK/plasma-session-lib" \
        bash "$session_control" "$1"
}

# The Y700 bring-up file sorts after the managed one, so it has to be cleared out.
printf '[Autologin]\nUser=armada\nSession=armada-plasma-mobile.desktop\nRelogin=true\n' \
    > "$sddm_dir/zz-y700-autologin.conf"
printf '[Autologin]\nSession=gamescope-session-steam.desktop\n' \
    > "$sddm_dir/zz-steamos-autologin.conf"
: > "$WORK/systemctl.log"

run_session_control switch-gamemode
assert_eq "$(sed -n 's/^Session=//p' "$sddm_dir/zz-holo-autologin.conf")" \
    gamescope-session-steam.desktop 'switch-gamemode writes the managed autologin file'
[[ ! -e "$sddm_dir/zz-y700-autologin.conf" ]] || fail 'the Y700 autologin file survived a switch'
[[ ! -e "$sddm_dir/zz-steamos-autologin.conf" ]] || fail 'the steamos autologin file survived a switch'
grep -q 'restart sddm.service' "$WORK/systemctl.log" \
    || fail 'switch-gamemode did not restart sddm after logout failed'

run_session_control default-session
assert_eq "$(sed -n 's/^Session=//p' "$sddm_dir/zz-holo-autologin.conf")" \
    armada-plasma-mobile.desktop 'a desktop device profile defaults to the Plasma desktop'
assert_eq "$(grep -c 'restart sddm.service' "$WORK/systemctl.log")" 1 \
    'default-session does not restart the session'

# A logout call that Plasma accepts but ignores must not leave the switch undone.
: > "$WORK/systemctl.log"
: > "$WORK/sleep.log"
SUDO_EXIT=0 QDBUS_EXIT=0 KWIN_EXIT=0 run_session_control switch-gamemode
grep -q 'restart sddm.service' "$WORK/systemctl.log" \
    || fail 'an ignored logout request did not fall back to a display manager restart'
assert_eq "$(wc -l < "$WORK/sleep.log")" 8 'the compositor was not given time to exit'

# A real logout must not restart the display manager a second time.
: > "$WORK/systemctl.log"
: > "$WORK/sleep.log"
SUDO_EXIT=0 QDBUS_EXIT=0 KWIN_EXIT=1 run_session_control switch-gamemode
assert_eq "$(grep -c 'restart sddm.service' "$WORK/systemctl.log")" 0 \
    'a confirmed logout still restarted the display manager'
assert_eq "$(wc -l < "$WORK/sleep.log")" 0 'a confirmed logout waited for the compositor'

# armada-fixups must fold the legacy names into the managed file exactly once.
MIGRATION_TEST="$WORK/migration-test.py"
cat > "$MIGRATION_TEST" <<PYEOF
import importlib.machinery
import importlib.util
import pathlib
import shutil
import sys
from unittest import mock

FIXUPS = sys.argv[1]
WORK = pathlib.Path(sys.argv[2])


def load():
    name = "armada_fixups_under_test"
    loader = importlib.machinery.SourceFileLoader(name, FIXUPS)
    spec = importlib.util.spec_from_file_location(name, loader=loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def sandbox(root):
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    return root


def run(module, root):
    with mock.patch.object(module, "SDDM_AUTOLUGIN_DIR", root):
        module.migrate_sddm_autologin()


def check(label, ok):
    print(("ok   " if ok else "FAIL ") + label)
    if not ok:
        sys.exit(1)


module = load()
root = sandbox(WORK / "fixups")
(root / "zz-y700-autologin.conf").write_text("[Autologin]\nSession=armada-plasma-mobile.desktop\n")
run(module, root)
check("the Y700 choice is carried into the managed file",
      (root / "zz-holo-autologin.conf").read_text() == "[Autologin]\nSession=armada-plasma-mobile.desktop\n")
check("the Y700 file is gone", not (root / "zz-y700-autologin.conf").exists())

root = sandbox(WORK / "fixups2")
(root / "zz-y700-autologin.conf").write_text("[Autologin]\nSession=old.desktop\n")
(root / "zz-holo-autologin.conf").write_text("[Autologin]\nSession=gamescope-session-steam.desktop\n")
run(module, root)
check("an explicit managed file wins",
      (root / "zz-holo-autologin.conf").read_text() == "[Autologin]\nSession=gamescope-session-steam.desktop\n")
check("the Y700 file is still removed", not (root / "zz-y700-autologin.conf").exists())

root = sandbox(WORK / "fixups3")
run(module, root)
check("no legacy file is a no-op", not (root / "zz-holo-autologin.conf").exists())
PYEOF
python3 "$MIGRATION_TEST" "$FIXUPS_SRC" "$WORK" || fail 'autologin migration checks failed'

printf 'sddm autologin session checks passed\n'
