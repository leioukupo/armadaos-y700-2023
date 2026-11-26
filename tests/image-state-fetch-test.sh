#!/usr/bin/env bash
# Test for devices/lenovo-tb320fc/rootfs/image-state-fetch.sh, the part of the adoption
# that pulls a multi-GB tar off the LAN, verifies it against factory-state.sha256 and
# unpacks it. Those are exactly the steps that on HA1WZJJ5 cost 20 minutes of Wi-Fi per
# attempt, so each mode gets checked here against a local HTTP server instead.
#
# Needs curl, tar and python3 (http.server); skips (exit 0) without them.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH="$ROOT_DIR/devices/lenovo-tb320fc/rootfs/image-state-fetch.sh"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

for tool in curl tar sha256sum python3; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is not installed"; exit 0; }
done
[[ -f "$FETCH" ]] || { echo "FAIL: no $FETCH"; exit 1; }

W=$(mktemp -d)
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf "$W"; return 0; }
trap cleanup EXIT

# A bundle in the shape pack-image-state.sh + stage-adopt-bundle.sh produce.
B="$W/bundle"; V="$W/stage"; S="$W/src"
mkdir -p "$B" "$V" "$S/var/home/armada/.local/share/Steam" "$S/etc/conf.d"
printf '#!/bin/sh\necho steam\n' >"$S/var/home/armada/.local/share/Steam/steam.sh"
chmod 0755 "$S/var/home/armada/.local/share/Steam/steam.sh"
printf 'secret\n' >"$S/var/home/armada/.bashrc"
printf 'root:x:0:0::/root:/bin/bash\n' >"$S/etc/passwd"
for i in $(seq 1 12); do printf 'x\n' >"$S/etc/conf.d/$i.conf"; done
( cd "$S" && tar -cf "$B/factory-var.tar" var )
( cd "$S" && tar -cf "$B/factory-etc.tar" etc )
( cd "$B" && sha256sum factory-var.tar factory-etc.tar >factory-state.sha256 )

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$PORT" --directory "$B" --bind 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 40); do
    curl -fs -o /dev/null "http://127.0.0.1:$PORT/factory-state.sha256" && break
    sleep 0.2
done
SRC="http://127.0.0.1:$PORT"

# --- the good path ------------------------------------------------------------
out=$("$FETCH" --src "$SRC" --auth armada:armada --out "$V" --tar factory-var.tar \
      --anchor var --headroom 1024 2>"$W/err"); rc=$?
check "a served state tar is fetched and unpacked" "[[ $rc == 0 ]]"
check "stdout is the directory to hand adopt.sh" "[[ $out == $V/var ]]"
check "the factory Steam client is where adopt.sh looks for it" \
      "[[ -x \$V/var/home/armada/.local/share/Steam/steam.sh ]]"
check "the sha of the bundle is verified" "grep -q 'sha256 verified' \"$W/err\""

out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-etc.tar --anchor etc --headroom 1024 2>/dev/null); rc=$?
check "no --auth is fine against an open server" "[[ $rc == 0 && \$out == $V/etc ]]"
check "a repeat run replaces the anchor instead of merging into it" \
      "grep -qx etc <(cd \"\$V\" && ls)"

# --- the modes that need distinct answers -------------------------------------
out=$("$FETCH" --src "$SRC" --out "$V" --tar no-such-tar.tar --anchor var 2>&1); rc=$?
check "a bundle without that tar exits 1, not 2" "[[ $rc == 1 ]]"

printf 'damaged' | dd of="$B/factory-var.tar" bs=1 seek=200 conv=notrunc status=none
out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-var.tar --anchor var --headroom 1024 2>&1); rc=$?
check "a tar whose bytes changed is refused" "[[ $rc == 2 ]]"
check "and it says the download is damaged" "grep -q 'does not match factory-state.sha256' <<<\"\$out\""
check "the damaged download is not left staged" "! [[ -f \$V/factory-var.tar ]]"

out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-etc.tar --anchor var --headroom 99999999999999 2>&1); rc=$?
check "a root with too little room fails before the transfer" \
      "[[ $rc == 2 ]] && grep -q 'not enough room' <<<\"\$out\""

out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-etc.tar --anchor var --headroom 1024 2>&1); rc=$?
check "an archive without the promised anchor fails" \
      "[[ $rc == 2 ]] && grep -q 'did not contain a var/ directory' <<<\"\$out\""

rm "$B/factory-state.sha256"
out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-etc.tar --anchor etc --headroom 1024 2>&1); rc=$?
check "an older bundle with no sha file still stages" \
      "[[ $rc == 0 ]] && grep -q 'unchecked' <<<\"\$out\""

out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-etc.tar 2>&1); rc=$?
check "a missing --anchor is refused" "[[ $rc == 2 ]] && grep -q -- '--anchor is required' <<<\"\$out\""
out=$("$FETCH" --src "$SRC" --out "$V" --tar factory-etc.tar --anchor etc --frobnicate 2>&1); rc=$?
check "an unknown option is refused" "[[ $rc == 2 ]] && grep -q 'unknown argument' <<<\"\$out\""

echo
if [[ "$fails" == 0 ]]; then
    echo "IMAGE_STATE_FETCH_TEST_OK"
    exit 0
fi
echo "IMAGE_STATE_FETCH_TEST_FAILED: $fails"
exit 1