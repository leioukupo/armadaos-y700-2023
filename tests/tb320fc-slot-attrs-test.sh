#!/bin/bash
# Tests for system_files/usr/libexec/tb320fc/slot-attrs.
#
# The device-side read path is proven on HA1WZJJ5 (report plus two dry runs
# under Android toybox, PROGRESS A187).  What this file proves is the part that
# must never be wrong on a real disk: the write path - patched attributes,
# rebuilt entry and header CRC32s, both GPT copies kept identical, idempotency,
# and refusal when the table is not trustworthy.
#
# The fixture is built with python3 because hand-writing a GPT is not the thing
# under test; slot-attrs itself never needs python on the device.
set -uo pipefail

cd "$(dirname "$0")/.."
TOOL=system_files/usr/libexec/tb320fc/slot-attrs
[ -x "$TOOL" ] || { echo "FAIL: $TOOL is missing or not executable"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: python3 needed to build the fixture"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
grep_ok(){ if printf '%s' "$2" | grep -q -- "$1"; then ok "$3"; else bad "$3 (no [$1] in: $(printf '%s' "$2" | tail -1))"; fi; }

LB=4096
IMG=$W/lu.img
PAIRS=4           # boot, vendor_boot, dtbo, vbmeta
ENTRIES=$((PAIRS * 2))

python3 - "$IMG" <<'PY'
import sys, struct, zlib
img = sys.argv[1]
LB, NLB, NUM, ESZ = 4096, 16, 96, 128
EQLBA, ALTLBA = 2, NLB - 1
BEQLBA = ALTLBA - (NUM * ESZ + LB - 1) // LB
data = bytearray(NLB * LB)

# The numbers are the ones measured on the device (PROGRESS A187): boot uses
# 7/2, the firmware partitions use 15/11, and slot b carries dont-boot-again.
# vbmeta_a/vbmeta_b deliberately hold the same value to cover the
# equal-priority (both-demoted) case.
PARTS = [
    ("boot_a",        0x0037000000000000),
    ("boot_b",        0x0082000000000000),
    ("vendor_boot_a", 0x00ff000000000000),
    ("vendor_boot_b", 0x007b000000000000),
    ("dtbo_a",        0x00ff000000000000),
    ("dtbo_b",        0x007b000000000000),
    ("vbmeta_a",      0x0077000000000000),
    ("vbmeta_b",      0x0077000000000000),
    ("userdata",      0x0000000000000000),
]
arr = bytearray(NUM * ESZ)
for i, (name, attrs) in enumerate(PARTS):
    e = bytearray(ESZ)
    e[0:16] = bytes([i + 1] * 16)
    e[16:32] = bytes([i + 0x40] * 16)
    e[32:40] = struct.pack("<Q", 6 + i)
    e[40:48] = struct.pack("<Q", 8 + i)
    e[48:56] = struct.pack("<Q", attrs)
    e[56:56 + 2 * len(name)] = name.encode("utf-16-le")
    arr[i * ESZ:(i + 1) * ESZ] = e

def header(mylba, altlba, eqlba, table):
    h = bytearray(92)
    h[0:8] = b"EFI PART"
    h[8:12] = struct.pack("<I", 0x10000)
    h[12:16] = struct.pack("<I", 92)
    h[24:32] = struct.pack("<Q", mylba)
    h[32:40] = struct.pack("<Q", altlba)
    h[40:48] = struct.pack("<Q", 5)
    h[48:56] = struct.pack("<Q", ALTLBA - 1)
    h[72:80] = struct.pack("<Q", eqlba)
    h[80:84] = struct.pack("<I", NUM)
    h[84:88] = struct.pack("<I", ESZ)
    h[88:92] = struct.pack("<I", zlib.crc32(table) & 0xffffffff)
    h[16:20] = struct.pack("<I", zlib.crc32(bytes(h)) & 0xffffffff)
    return h

data[1 * LB:1 * LB + 92] = header(1, ALTLBA, EQLBA, bytes(arr))
data[EQLBA * LB:EQLBA * LB + len(arr)] = arr
data[BEQLBA * LB:BEQLBA * LB + len(arr)] = arr
data[ALTLBA * LB:ALTLBA * LB + 92] = header(ALTLBA, 1, BEQLBA, bytes(arr))
open(img, "wb").write(bytes(data))
PY
[ -s "$IMG" ] || { echo "FAIL: fixture not built"; exit 1; }

# verify prints one token per entry plus the two CRC verdicts, so the
# assertions below can check "both copies valid" without re-implementing GPT.
verify() {
  python3 - "$IMG" <<'PY'
import sys, struct, zlib
d = open(sys.argv[1], "rb").read()
LB = 4096
def hdr(off):
    return dict(hlen=struct.unpack("<I", d[off+12:off+16])[0],
                hcrc=struct.unpack("<I", d[off+16:off+20])[0],
                eqlba=struct.unpack("<Q", d[off+72:off+80])[0],
                num=struct.unpack("<I", d[off+80:off+84])[0],
                esz=struct.unpack("<I", d[off+84:off+88])[0],
                ecrc=struct.unpack("<I", d[off+88:off+92])[0])
res = []
for off in (LB, len(d) - LB):
    h = hdr(off)
    arr = d[h["eqlba"]*LB:h["eqlba"]*LB + h["num"]*h["esz"]]
    hh = bytearray(d[off:off+h["hlen"]]); hh[16:20] = b"\0\0\0\0"
    res.append("crc_arr=%d crc_hdr=%d" %
               (zlib.crc32(arr) & 0xffffffff == h["ecrc"],
                zlib.crc32(bytes(hh)) & 0xffffffff == h["hcrc"]))
    for i in range(h["num"]):
        e = arr[i*h["esz"]:i*h["esz"]+128]
        if e[:16] == b"\0" * 16: continue
        name = e[56:128].decode("utf-16-le").rstrip("\0")
        a = struct.unpack("<Q", e[48:56])[0]
        res.append("%s prio=%d dont=%d" % (name, (a >> 48) & 0xf, (a >> 55) & 1))
print("|".join(res))
PY
}

cp "$IMG" "$IMG.orig"
run() { sub=$1; shift; sh "$TOOL" "$sub" --disk "$IMG" --lba-size $LB "$@" 2>&1; }

out=$(run report)
grep_ok "pairs=$PAIRS" "$out" "report counts the $PAIRS slot pairs"
grep_ok "^  boot  *a\[prio=7  succ=1 fail=1 facres=0 dont=0\] b\[prio=2  succ=0 fail=0 facres=0 dont=1\]$" \
  "$out" "report shows the demoted-slot-b layout the device really had"
printf '%s\n' "$out" | grep -q userdata && bad "report listed a non-slot partition" || ok "report ignores non-slot partitions"

out=$(run set --slot b)
grep_ok "entries_to_change=$ENTRIES written=0 (dry run" "$out" "dry run lists every pair but writes nothing"
cmp -s "$IMG" "$IMG.orig" && ok "dry run left the image untouched" || bad "dry run modified the image"

out=$(run set --slot b --commit)
grep_ok "SLOTATTRS-OK cmd=set slot=b entries_written=$ENTRIES verified=1 pre_dump=" "$out" "commit reports a verified write plus a pre-image dump"
out=$(verify)
n=$(printf '%s\n' "$out" | tr '|' '\n' | grep -c "crc_arr=1 crc_hdr=1")
check "both GPT copies still pass their CRC32s" "$n" "2"
printf '%s\n' "$out" | tr '|' '\n' | grep -q "crc_arr=0\|crc_hdr=0" && bad "a CRC went stale" || ok "no stale CRC after the write"
grep_ok "boot_b prio=7 dont=0" "$out" "boot_b became the preferred boot (no dont-boot-again)"
grep_ok "boot_a prio=2" "$out" "boot_a dropped to the pair's lower priority"
grep_ok "vendor_boot_b prio=15" "$out" "vendor_boot_b raised to 15"
grep_ok "vbmeta_b prio=15 dont=0" "$out" "equal-priority pair resolved to 15/11 for the target"
grep_ok "vbmeta_a prio=11" "$out" "equal-priority pair demoted the other side to 11"

out=$(run set --slot b --commit)
grep_ok "written=0 already_preferred=1" "$out" "running it again changes nothing"
out=$(run set --slot a --commit)
grep_ok "entries_written=$ENTRIES" "$out" "switching back writes again"
grep_ok "boot_a prio=7 dont=0" "$(verify)" "slot a is preferred again after the round trip"

# Corrupt the primary array so its own CRC breaks: the tool must refuse.
cp "$IMG.orig" "$IMG"
python3 - "$IMG" <<'PY'
import sys
img = sys.argv[1]; d = bytearray(open(img, "rb").read())
d[2 * 4096 + 52] ^= 0xFF
open(img, "wb").write(bytes(d))
PY
before=$(sha256sum "$IMG" | cut -d' ' -f1)
out=$(run set --slot b --commit)
printf '%s\n' "$out" | grep -q "CRC mismatch" && ok "refuses a table that fails its own CRC32" || bad "wrong refusal: $(printf '%s' "$out" | tail -1)"
check "refusal left the image byte-identical" "$(sha256sum "$IMG" | cut -d' ' -f1)" "$before"

# The subtler one: both CRCs valid but the two copies disagree.  Picking a side
# by guessing is how a device ends up unbootable, so this must refuse too.
cp "$IMG.orig" "$IMG"
python3 - "$IMG" <<'PY'
import sys, struct, zlib
img = sys.argv[1]; d = bytearray(open(img, "rb").read())
LB, EQLBA, ALTLBA = 4096, 2, 15
arr = d[EQLBA*LB:EQLBA*LB + 96*128]
arr[1 * 128 + 52] ^= 0xFF                      # change boot_b's priority bytes
d[EQLBA*LB:EQLBA*LB + len(arr)] = arr
for hoff in (LB,):                             # re-sign the PRIMARY header only;
    e = bytearray(d[hoff:hoff+92])             # the backup copy stays valid for
    e[88:92] = struct.pack("<I", zlib.crc32(bytes(arr)) & 0xffffffff)
    e[16:20] = b"\0\0\0\0"
    e[16:20] = struct.pack("<I", zlib.crc32(bytes(e)) & 0xffffffff)
    d[hoff:hoff+92] = e
open(img, "wb").write(bytes(d))
PY
before=$(sha256sum "$IMG" | cut -d' ' -f1)
out=$(run set --slot b --commit)
printf '%s\n' "$out" | grep -q "arrays differ" && ok "refuses when the two copies disagree" || bad "wrong refusal: $(printf '%s' "$out" | tail -1)"
check "second refusal left the image byte-identical" "$(sha256sum "$IMG" | cut -d' ' -f1)" "$before"

# The reason this lives in system_files/ is that it has to be on the device the
# next time the slots get demoted, so it must be part of what the overlay push
# copies onto a running board.
if grep -q "usr/libexec/tb320fc/slot-attrs" devices/lenovo-tb320fc/usr-overlay/push.sh; then
  ok "push.sh carries the helper onto a live board"
else
  bad "helper is not in usr-overlay/push.sh's file list"
fi

# ---------------------------------------------------------------------------
# pin: the same priority re-arrangement plus dont-boot-again on the peer, which
# is the state Android leaves behind after a verified boot.  A payload Linux
# never reports "boot completed", so this is the state that has to be re-written
# every boot or XBL keeps demoting slots (PROGRESS.md A194).  --pair keeps the
# write to the pair that actually drifts.
# ---------------------------------------------------------------------------
cp "$IMG.orig" "$IMG"
out=$(run pin --slot b --pair boot)
grep_ok "entries_to_change=2 written=0 (dry run" "$out" "pin --pair boot plans only the boot pair"
cmp -s "$IMG" "$IMG.orig" && ok "pin dry run left the image untouched" || bad "pin dry run modified the image"

out=$(run pin --slot b --pair boot --commit)
grep_ok "SLOTATTRS-OK cmd=pin slot=b entries_written=2 verified=1 pre_dump=" "$out" "pin commits exactly two entries"
v=$(verify)
n=$(printf '%s\n' "$v" | tr '|' '\n' | grep -c "crc_arr=1 crc_hdr=1")
check "both GPT copies still pass their CRC32s after pin" "$n" "2"
grep_ok "boot_b prio=7 dont=0" "$v" "pin makes boot_b the preferred boot slot"
grep_ok "boot_a prio=2 dont=1" "$v" "pin marks boot_a dont-boot-again so XBL cannot fall back to it"
grep_ok "vendor_boot_a prio=15" "$v" "pin --pair boot leaves the firmware pairs alone"

out=$(run pin --slot b --pair boot --commit)
grep_ok "written=0 already_pinned=1" "$out" "running pin again changes nothing"

out=$(run pin --slot b)
grep_ok "entries_to_change=$ENTRIES written=0" "$out" "pin without --pair plans every slot pair"
out=$(run pin --slot b --pair nosuchpair --commit)
printf '%s\n' "$out" | grep -q "no such slot pair" && ok "pin refuses an unknown --pair name" || bad "unknown pair: $(printf '%s' "$out" | tail -1)"

out=$(run pin --slot b --pair boot --prio 15 --peer-prio 0 --commit)
v=$(verify)
grep_ok "boot_b prio=15 dont=0" "$v" "--prio raises the pinned slot to an explicit priority"
grep_ok "boot_a prio=0" "$v" "--peer-prio demotes the other side to an explicit priority"
out=$(run pin --slot b --pair boot --prio 16)
printf '%s\n' "$out" | grep -q "0-15" && ok "--prio rejects a value outside 0-15" || bad "prio range: $(printf '%s' "$out" | tail -1)"

# ---------------------------------------------------------------------------
# slot-pin is what the systemd unit execs: it reads the conf, gates on the board
# DT, and hands slot-attrs the pin arguments.  All three inputs are overridable,
# so the whole ExecStart path is exercised against the fixture image here.
# ---------------------------------------------------------------------------
HELPER=system_files/usr/libexec/tb320fc/slot-pin
UNIT=system_files/usr/lib/systemd/system/tb320fc-slot-pin.service
CONF=system_files/etc/tb320fc/slot-pin.conf
[ -x "$HELPER" ] && ok "slot-pin helper is executable" || bad "slot-pin helper missing or not executable"
[ -f "$UNIT" ] && ok "the unit file ships in /usr/lib" || bad "unit file missing"
grep -q "ExecStart=/usr/libexec/tb320fc/slot-pin" "$UNIT" && ok "unit execs the helper" || bad "unit ExecStart wrong"
grep -q "^systemctl enable tb320fc-slot-pin.service$" build_files/40-vendor-system-files.sh \
  && ok "the image enables tb320fc-slot-pin.service" || bad "unit is not enabled by the image build"
for f in usr/libexec/tb320fc/slot-pin usr/lib/systemd/system/tb320fc-slot-pin.service etc/tb320fc/slot-pin.conf; do
  grep -q "$f" devices/lenovo-tb320fc/usr-overlay/push.sh && ok "push.sh carries $f" || bad "push.sh does not carry $f"
done
grep -q "^pin=on$" "$CONF" && ok "conf ships with the repair armed" || bad "conf default pin"
grep -q "^slot=b$" "$CONF" && ok "conf names the payload slot" || bad "conf default slot"
grep -q "^pairs=boot$" "$CONF" && ok "conf narrows the write to the boot pair" || bad "conf default pairs"

printf 'lenovo,tb320fc\0' > "$W/compat"
pinconf() { printf 'slot=b\npairs=boot\ncommit=%s\n%s\n' "$1" "$2" > "$W/pin.conf"; }
cp "$IMG.orig" "$IMG"
pinconf on ""
out=$(TB320FC_DT_COMPATIBLE="$W/compat" TB320FC_SLOT_PIN_CONF="$W/pin.conf" TB320FC_SLOT_DEV="$IMG" sh "$HELPER" 2>&1)
grep_ok "TB320FC-SLOT-PIN-v1 start slot=b pairs=boot commit=on" "$out" "slot-pin logs the settings it used"
grep_ok "SLOTATTRS-OK cmd=pin slot=b entries_written=2 verified=1" "$out" "slot-pin drives pin to a verified write"
grep_ok "TB320FC-SLOT-PIN-v1 done rc=0" "$out" "slot-pin reports success"
grep_ok "boot_a prio=2 dont=1" "$(verify)" "slot-pin left the boot pair pinned to slot b"

cp "$IMG.orig" "$IMG"
pinconf on "pin=off"
out=$(TB320FC_DT_COMPATIBLE="$W/compat" TB320FC_SLOT_PIN_CONF="$W/pin.conf" TB320FC_SLOT_DEV="$IMG" sh "$HELPER" 2>&1)
grep_ok "skip pin=off" "$out" "pin=off is a kill switch"
cmp -s "$IMG" "$IMG.orig" && ok "kill switch left the image untouched" || bad "kill switch wrote anyway"

pinconf off ""
out=$(TB320FC_DT_COMPATIBLE="$W/compat" TB320FC_SLOT_PIN_CONF="$W/pin.conf" TB320FC_SLOT_DEV="$IMG" sh "$HELPER" 2>&1)
grep_ok "cmd=pin slot=b entries_to_change=2 written=0 (dry run" "$out" "commit=off keeps the unit in dry run"
cmp -s "$IMG" "$IMG.orig" && ok "dry-run unit left the image untouched" || bad "commit=off wrote anyway"

printf 'tb320fc-not-this-board\0' > "$W/compat-other"
out=$(TB320FC_DT_COMPATIBLE="$W/compat-other" TB320FC_SLOT_PIN_CONF="$W/pin.conf" TB320FC_SLOT_DEV="$IMG" sh "$HELPER" 2>&1)
grep_ok "skip board-mismatch" "$out" "the helper no-ops on another board"
cmp -s "$IMG" "$IMG.orig" && ok "board gate left the image untouched" || bad "board gate wrote anyway"

out=$(run report --disk /dev/null)
printf '%s\n' "$out" | grep -q "not a block device or image file" && ok "refuses a character device" || bad "char device: $(printf '%s' "$out" | tail -1)"

printf '%s tests=%s pass=%s fail=%s\n' "TB320FC-SLOTATTRS-TEST" "$((pass+fail))" "$pass" "$fail"
[ "$fail" = 0 ]
