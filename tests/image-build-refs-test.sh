#!/usr/bin/env bash
#
# The image build resolves one container ref per Containerfile ARG.
#
# `just build` walks packages/*/ with a build.sh, then checks that the number of
# refs it resolved equals the number of `ARG <NAME>_REF` lines in the Containerfile.
# Two package directories (btop-cn, kshim-tools) are kept in the tree and published
# by the packages workflow but no longer installed into the image, so the walk had
# two more entries than the ARG list and every build stopped with
# "Containerfile wants 24 refs, resolved 26" before starting podman.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERFILE="$ROOT/Containerfile"
JUSTFILE="$ROOT/Justfile"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok %s\n' "$*"; }

[ -f "$CONTAINERFILE" ] || fail "missing $CONTAINERFILE"
[ -f "$JUSTFILE" ] || fail "missing $JUSTFILE"

# --- the two sets, normalized to package directory names ----------------------
args="$(sed -n 's/^ARG \([A-Z0-9_]*\)_REF$/\1/p' "$CONTAINERFILE" | tr 'A-Z' 'a-z' | sed 's/_/-/g' | sort -u)"
built="$(for dir in "$ROOT"/packages/*/; do
            pkg="$(basename "$dir")"
            [ -f "$dir/build.sh" ] || continue
            printf '%s\n' "$pkg"
        done | sort -u)"
referenced="$(while IFS= read -r pkg; do
                  var="$(printf '%s' "$pkg" | tr '[:lower:]-' '[:upper:]_')_REF"
                  grep -q "^ARG ${var}\$" "$CONTAINERFILE" && printf '%s\n' "$pkg"
              done <<<"$built" | sort -u)"

n_args=$(grep -c '^ARG [A-Z0-9_]*_REF$' "$CONTAINERFILE")
n_ref=$(printf '%s\n' "$referenced" | grep -c .)
[ "$n_args" -eq "$n_ref" ] || fail "Containerfile declares $n_args ARG refs, $n_ref packages are referenced by them"
ok "every Containerfile ARG ref maps to a built package ($n_args)"

unreferenced="$(comm -13 <(printf '%s\n' "$referenced") <(printf '%s\n' "$built"))"
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    printf 'note %s is built but not installed by the image\n' "$pkg"
done <<<"$unreferenced"

# --- the build recipe has to skip exactly those, not fail on them -------------
build_recipe="$(awk '$0 == "build $target_image=image_name $tag=default_tag:" { f = 1; next }
                       f && $0 !~ /^[ \t]/ && $0 != "" { exit }
                       f { print }' "$JUSTFILE")"
[ -n "$build_recipe" ] || fail "could not extract the build recipe from the Justfile"
grep -q 'grep -q "\^ARG \${var}\$"' <<<"$build_recipe" \
    || fail 'the build recipe does not skip packages the Containerfile does not reference'
ok "the build recipe skips packages with no ARG ref"
grep -q 'Containerfile wants \${expected} refs, resolved \${got}' <<<"$build_recipe" \
    || fail 'the build recipe no longer checks the resolved ref count'
ok "the build recipe still checks that every ARG got a ref"

printf '\nAll image-build ref tests passed.\n'
