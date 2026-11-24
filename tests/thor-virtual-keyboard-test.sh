#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
    local file="$1" needle="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        printf 'missing %s in %s\n' "$needle" "$file" >&2
        exit 1
    fi
}

assert_contains_many() {
    local needle="$1"
    shift
    if ! grep -Fq -- "$needle" "$@"; then
        printf 'missing %s in %s\n' "$needle" "$*" >&2
        exit 1
    fi
}

assert_contains "$ROOT/system_files/usr/lib/armada/devices/defaults.conf" 'ARMADA_VIRTUAL_KEYBOARD_CONNECTOR='
assert_contains "$ROOT/system_files/usr/lib/armada/devices/ayn-thor.conf" 'ARMADA_VIRTUAL_KEYBOARD_CONNECTOR=DSI-1'
assert_contains "$ROOT/system_files/usr/lib/armada/devices/ayn-thor-lite.conf" 'ARMADA_VIRTUAL_KEYBOARD_CONNECTOR=DSI-2'
assert_contains "$ROOT/system_files/usr/libexec/armada/device-env" 'ARMADA_VIRTUAL_KEYBOARD_CONNECTOR'
assert_contains "$ROOT/system_files/usr/libexec/armada/armada-plasma-session" '/usr/libexec/armada/device-env'
assert_contains "$ROOT/system_files/usr/libexec/armada/armada-plasma-session" 'set -a'
assert_contains "$ROOT/Containerfile" 'ARG KWIN_REF'
assert_contains "$ROOT/Containerfile" 'FROM ${KWIN_REF} AS kwin'
assert_contains "$ROOT/packages/Containerfile" 'FROM scratch AS out-kwin'
assert_contains "$ROOT/Containerfile" '--mount=type=bind,from=kwin,source=/rpms,target=/packages/kwin'
# 10-base-packages.sh only chains the three package groups, so the locally
# pinned KWin RPMs are looked for in the groups that install them.
BASE_PACKAGES=(
    "$ROOT/build_files/10a-core.sh"
    "$ROOT/build_files/10b-desktop.sh"
    "$ROOT/build_files/10c-apps.sh"
)
assert_contains_many '/packages/kwin/kwin-[0-9]*.rpm' "${BASE_PACKAGES[@]}"
assert_contains_many '/packages/kwin/kwin-common-[0-9]*.rpm' "${BASE_PACKAGES[@]}"
assert_contains_many '/packages/kwin/kwin-libs-[0-9]*.rpm' "${BASE_PACKAGES[@]}"

printf 'Thor virtual keyboard packaging test passed\n'
