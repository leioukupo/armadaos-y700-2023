#!/usr/bin/env bash
# Test for devices/lenovo-tb320fc/rootfs/pack-image-state.sh.
#
# Needs no root, no loop device and no podman: it builds an image-shaped tree in a
# temporary directory and checks what the packager refuses to package as much as what it
# writes. The defect this exists to prevent is a bundle that is quietly incomplete - the
# adoption on HA1WZJJ5 shipped a commit with an empty /var and Steam repair then died on
# "No such file or directory: /var/home/armada" (PROGRESS A221).
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER="$ROOT_DIR/devices/lenovo-tb320fc/rootfs/pack-image-state.sh"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

for tool in tar sha256sum realpath mktemp stat; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is not installed"; exit 0; }
done
[[ -f "$PACKER" ]] || { echo "FAIL: no $PACKER"; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
T="$W/tree"; O="$W/out"

# An image root in miniature. The entry counts are padded on purpose: --min-entries is a
# "you pointed at the wrong directory" floor, so the fixture has to sit above it the same
# way a real image does (a real /etc has ~200 top-level entries, /var/home ~20 000 files).
mkdir -p "$T/usr/lib" "$T/etc/conf.d" "$T/var/home/armada/.local/share/Steam/sdk" \
         "$T/var/home/armada/.config" "$T/var/roothome" "$O"
printf 'NAME=fixture\n' >"$T/usr/lib/os-release"
printf 'root:x:0:0::/root:/bin/bash\n' >"$T/etc/passwd"
for i in $(seq 1 12); do printf 'x\n' >"$T/etc/conf.d/$i.conf"; done
printf '#!/bin/sh\necho steam\n' >"$T/var/home/armada/.local/share/Steam/steam.sh"
chmod 0755 "$T/var/home/armada/.local/share/Steam/steam.sh"
printf '{"a":1}\n' >"$T/var/home/armada/.local/share/Steam/sdk/manifest.json"
printf 'secret\n' >"$T/var/roothome/.bashrc"
for i in $(seq 1 12); do printf 'y\n' >"$T/var/home/armada/.config/$i"; done

out=$("$PACKER" --tree "$T" --out "$O" 2>&1)
check "a complete image tree packs" "grep -q IMAGE_STATE_OK <<<\"\$out\""
check "both tars are written" "[[ -f \$O/factory-etc.tar && -f \$O/factory-var.tar ]]"
check "no .tmp left behind" "! ls \$O/*.tmp >/dev/null 2>&1"

tar -tf "$O/factory-var.tar" >"$W/var.list"
check "the var tar carries the factory Steam client" \
      "grep -q 'var/home/armada/.local/share/Steam/steam.sh' \"$W/var.list\""
check "the var tar carries roothome" "grep -q '^var/roothome/.bashrc\$' \"$W/var.list\""
tar -tf "$O/factory-etc.tar" >"$W/etc.list"
check "the etc tar carries the image /etc" "grep -q '^etc/passwd\$' \"$W/etc.list\""

# adopt-run-board.sh extracts into \$V and then requires \$V/var, so the archive has to
# carry its own top-level directory instead of being rooted at the content.
mkdir -p "$W/x"
tar -xf "$O/factory-var.tar" -C "$W/x"
check "extracting the var tar yields a var/ directory" "[[ -d \$W/x/var/home/armada ]]"
check "the mode of steam.sh survives the round trip" \
      "[[ \$(stat -c %a \"\$W/x/var/home/armada/.local/share/Steam/steam.sh\") == 755 ]]"
check "the sha list matches the tars" "( cd \"\$O\" && sha256sum -c --quiet factory-state.sha256 )"
check "factory-state.txt names the source" "grep -q \"source=\$T\" \"\$O/factory-state.txt\""
check "factory-state.txt counts the var entries" "grep -q 'factory-var.tar .*entries=' \"\$O/factory-state.txt\""

# ---------------------------------------------------------------------------
# The refusals. Each of these is how a half-made bundle reaches the tablet today.
# ---------------------------------------------------------------------------
rm -rf "$O"; mkdir -p "$O"
out=$("$PACKER" --tree "$W" --out "$O" 2>&1)
check "a directory that is not an image root is refused" \
      "grep -q 'not an image root' <<<\"\$out\""
check "nothing is written when the tree is rejected" "! ls \$O/factory-*.tar >/dev/null 2>&1"

out=$("$PACKER" --tree "$T" --out "$T/bundle" 2>&1)
check "an --out inside the packed tree is refused" "grep -q 'inside the tree' <<<\"\$out\""

out=$("$PACKER" --tree "$T" --out "$O" --min-entries 100000 2>&1)
check "an implausible --min-entries fails instead of packing anyway" \
      "grep -q 'a mistyped or empty source directory' <<<\"\$out\""
out=$("$PACKER" --tree "$T" --out "$O" --min-entries 3 2>&1)
check "a small --min-entries still packs the fixture" "grep -q IMAGE_STATE_OK <<<\"\$out\""

# A tree whose /var has no home at all (the flat root of a build without the Steam
# bootstrap, or simply the wrong directory mounted).
T2="$W/tree2"
mkdir -p "$T2/usr/lib" "$T2/etc/conf.d" "$T2/var/lib/systemd"
printf 'NAME=fixture2\n' >"$T2/usr/lib/os-release"
printf 'root:x:0:0::/root:/bin/bash\n' >"$T2/etc/passwd"
for i in $(seq 1 12); do printf 'x\n' >"$T2/etc/conf.d/$i.conf"; done
out=$("$PACKER" --tree "$T2" --out "$O" 2>&1)
check "a tree with no var/home says so plainly" "grep -q 'none of \[var/home var/roothome\] exists' <<<\"\$out\""

# Steam missing but /var present: warn by default, fail on request.
T3="$W/tree3"
mkdir -p "$T3/usr/lib" "$T3/etc/conf.d" "$T3/var/home/armada/.local/share" "$T3/var/roothome"
printf 'NAME=fixture3\n' >"$T3/usr/lib/os-release"
printf 'root:x:0:0::/root:/bin/bash\n' >"$T3/etc/passwd"
for i in $(seq 1 12); do printf 'x\n' >"$T3/etc/conf.d/$i.conf"; done
for i in $(seq 1 12); do printf 'z\n' >"$T3/var/home/armada/.local/share/$i"; done
out=$("$PACKER" --tree "$T3" --out "$O" 2>&1)
check "no factory Steam is a warning by default" \
      "grep -q 'no factory Steam' <<<\"\$out\" && grep -q IMAGE_STATE_OK <<<\"\$out\""
out=$("$PACKER" --tree "$T3" --out "$O" --require-steam 2>&1)
check "--require-steam turns it into a failure" \
      "grep -q 'nothing to export' <<<\"\$out\" && ! grep -q IMAGE_STATE_OK <<<\"\$out\""
check "the failed run leaves no truncated var tar" "! ls \$O/factory-var.tar.tmp >/dev/null 2>&1"

# --var-paths lets another image decide what image-owned /var means.
rm -rf "$O"; mkdir -p "$O"
out=$("$PACKER" --tree "$T" --out "$O" --var-paths "var/home" 2>&1)
check "--var-paths packs the listed subset" "grep -q IMAGE_STATE_OK <<<\"\$out\""
tar -tf "$O/factory-var.tar" >"$W/sub.list" 2>/dev/null
check "--var-paths keeps the unlisted path out" "! grep -q 'var/roothome' \"$W/sub.list\""

out=$("$PACKER" --out "$O" 2>&1)
check "a run without --image or --tree is refused" "grep -q 'give --image REF or --tree DIR' <<<"\$out""
out=$("$PACKER" --tree "$T" --out "$O" --frobnicate 2>&1)
check "an unknown option is refused" "grep -q 'unknown argument' <<<"\$out""
out=$("$PACKER" --tree "$T" 2>&1)
check "--out is required" "grep -q -- '--out DIR is required' <<<"\$out""

echo
if [[ "$fails" == 0 ]]; then
    echo "IMAGE_STATE_TEST_OK"
    exit 0
fi
echo "IMAGE_STATE_TEST_FAILED: $fails"
exit 1