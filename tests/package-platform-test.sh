#!/usr/bin/env bash
# Which architecture each package is built for, and that a foreign one fails loudly.
#
# `just package` runs the Containerfile stages through buildah, which defaults to
# the host arch. On an x86_64 dev box that built an x86_64 terra-gamescope and fed
# Armada's arm64 march flags into an x86 spec, so meson died with "Compiler gcc
# cannot compile programs"; a wrong-arch package image that got past that would
# only fail much later, inside the arm64 image build.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/packages"
HELPER="$PKG/target-platform.sh"
JUSTFILE="$ROOT/Justfile"
BUILD_LOCAL="$PKG/build-local.sh"
GAMESCOPE="$PKG/gamescope/build.sh"
for f in "$HELPER" "$JUSTFILE" "$BUILD_LOCAL" "$GAMESCOPE"; do
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

# --- the mapping lives in one place -------------------------------------------
for pkg in mesa-android lepton mesa-x86; do
    assert_eq "$(bash "$HELPER" "$pkg")" "linux/amd64" "$pkg builds on an x86_64 host"
done
for pkg in gamescope gamescope-session gamescope-session-steam kernel mesa armada-rgb; do
    assert_eq "$(bash "$HELPER" "$pkg")" "linux/arm64" "$pkg targets arm64"
done

# --- both local entry points read it -----------------------------------------
grep -q 'target-platform\.sh' "$BUILD_LOCAL" \
    || fail 'build-local.sh does not use target-platform.sh'
printf 'ok   build-local.sh takes its platform from the helper\n'
grep -q '^platform=linux/aarch64$' "$BUILD_LOCAL" \
    && fail 'build-local.sh still hardcodes a platform'
printf 'ok   build-local.sh no longer hardcodes a platform\n'

recipe() {
    awk -v header="$1" '$0 == header { f = 1; next }
         f && $0 !~ /^[ \t]/ && $0 != "" { exit }
         f { print }' "$JUSTFILE"
}

package_recipe="$(recipe 'package name:')"
[[ -n "$package_recipe" ]] || fail 'could not extract the package recipe from the Justfile'
grep -q 'packages/target-platform\.sh' <<<"$package_recipe" \
    || fail 'the package recipe does not resolve a platform'
printf 'ok   just package resolves the platform\n'
grep -q -- '--platform "${platform}"' <<<"$package_recipe" \
    || fail 'the package recipe does not pass --platform to buildah'
printf 'ok   just package passes --platform to buildah\n'

grep -q 'is a ${arch} image' "$JUSTFILE" \
    || fail 'the image build does not reject a wrong-arch local package image'
printf 'ok   just build rejects wrong-arch local package images\n'

# --- a foreign arch fails at once, not half an hour into meson ----------------
bash -n "$GAMESCOPE" || fail 'gamescope build.sh does not parse'
bash -n "$BUILD_LOCAL" || fail 'build-local.sh does not parse'
printf 'ok   gamescope build.sh and build-local.sh parse\n'

awk '/# BEGIN TARGET-ARCH GUARD/{f=1;next} /# END TARGET-ARCH GUARD/{f=0} f' \
    "$GAMESCOPE" >"$WORK/guard.sh"
[[ -s "$WORK/guard.sh" ]] || fail 'gamescope build.sh has no target-arch guard'

mkdir -p "$WORK/stub"
cat >"$WORK/stub/rpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$FAKE_ARCH"
STUB
chmod +x "$WORK/stub/rpm"

out="$(PATH="$WORK/stub:$PATH" FAKE_ARCH=x86_64 bash "$WORK/guard.sh" 2>&1)"
rc=$?
assert_eq "$rc" "1" "gamescope refuses an x86_64 builder"
assert_eq "$(printf '%s' "$out" | grep -c 'arm64 package but this builder targets x86_64')" "1" \
    "the refusal says which arch was wrong"

out="$(PATH="$WORK/stub:$PATH" FAKE_ARCH=aarch64 bash "$WORK/guard.sh" 2>&1)"
rc=$?
assert_eq "$rc" "0" "gamescope accepts the aarch64 builder"
assert_eq "$out" "" "the guard stays quiet on arm64"
