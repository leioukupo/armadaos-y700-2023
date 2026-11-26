#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Write every image an EDL package references, at the sector the package itself names,
# resumably. TB320FC (Y700 Gen 2), firehose over USB.
#
#   EDL_ROM=/path/to/unpacked_rom EDL_PY="…/python …/edl.py" install/rom-flash.sh
#
# Two things this deliberately does NOT do, both learned the hard way (PROGRESS A204):
#   * it skips the rom's gpt_* entries - the rom's table is built for its own geometry and
#     its patch*.xml rewrites LUN0, which would delete linuxroot by accident; GPTs are
#     rebuilt from the live dumps by gpt-stock.py / gpt-slice-pin.py instead;
#   * it skips zeros_5sectors.bin, but that entry is NOT noise: it clears the DDR training
#     cache (LUN3 lba 64). edl-restore.sh does that write explicitly. Never filter
#     zero-fill entries the way a "filename looks special" filter would.
set -uo pipefail

EDL_ROM=${EDL_ROM:?EDL_ROM=<unpacked edl package>}
EDL=${EDL:?EDL="<python> <edl.py> --loader=… --memory=ufshcd"}
WORK=${WORK:-$EDL_ROM}
RAWS=${RAWS:-"rawprogram1.xml rawprogram_unsparse0.xml rawprogram_unsparse4.xml rawprogram3.xml rawprogram2.xml rawprogram5.xml"}
cd "$EDL_ROM" || exit 1
: > "$WORK/done.txt"

python3 - "$WORK/order.txt" $RAWS <<'PY'
import sys, xml.etree.ElementTree as ET
out, seen = sys.argv[1], set()
with open(out, "w") as fh:
    for xr in sys.argv[2:]:
        for p in ET.parse(xr).getroot().iter("program"):
            a = p.attrib; fn = a.get("filename", "")
            if not fn or fn.startswith("gpt_") or fn == "zeros_5sectors.bin":
                continue
            key = (a["physical_partition_number"], a["start_sector"], fn)
            if key in seen:
                continue
            seen.add(key)
            fh.write("%s %s %s\n" % key)
PY

n=$(wc -l < "$WORK/order.txt"); i=0
while read -r lun sec fn; do
    i=$((i + 1))
    if grep -q "^$lun $sec $fn\$" "$WORK/done.txt" 2>/dev/null; then echo "skip $fn"; continue; fi
    printf '[%d/%d] lun%s lba=%s %s ... ' "$i" "$n" "$lun" "$sec" "$fn"
    out=$(timeout 1800 $EDL ws "$sec" "$fn" --lun="$lun" 2>&1 | tail -1)
    case "$out" in
        Wrote*) echo "OK"; echo "$lun $sec $fn" >> "$WORK/done.txt" ;;
        *)      echo "FAIL: $out"; exit 2 ;;
    esac
done < "$WORK/order.txt"
echo "ALL_WRITES_DONE $(wc -l < "$WORK/done.txt")/$n"