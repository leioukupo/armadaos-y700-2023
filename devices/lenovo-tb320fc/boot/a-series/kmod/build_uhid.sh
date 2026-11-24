#!/bin/bash
# Build the extra kernel modules this board stages but the OS image cannot ship.
#
# uhid.ko is what /dev/uhid needs for InputPlumber's deck-uhid target (see
# system_files/usr/libexec/tb320fc/input).  It has to be built against the exact
# kernel the A-series boot payload runs, because that kernel has no
# CONFIG_MODVERSIONS: the only gate is vermagic, which must read
#   7.3.0-rc6 SMP preempt mod_unload aarch64
# The asphalt tree is the same source the payload came from, so a single module
# target is enough - a few seconds, no Image/dtbs rebuild.
#
#   SRC=/srv/y700/kbuild9/src OUT=/usr/local/lib/y700 ./build_uhid.sh
set -uo pipefail
SRC=${SRC:?set SRC to the asphalt kernel source tree}
BUILD=$SRC/build
OUT=${OUT:-/usr/local/lib/y700}
JOBS=${JOBS:-4}
[ -f "$BUILD/.config" ] || { echo "NO_CONFIG in $BUILD (run the kernel build once)"; exit 1; }
# cpufreq_conservative.ko is the other one: system_files/usr/lib/modules-load.d/
# armada-handheld.conf asks kmod for it, but that path needs
# /usr/lib/modules/$(uname -r)/modules.dep, and the A-series payload ships no such
# directory - so armada-powerd silently loses its "conservative" governor.
MODULES="CONFIG_UHID:drivers/hid/uhid.ko CONFIG_CPU_FREQ_GOV_CONSERVATIVE:drivers/cpufreq/cpufreq_conservative.ko"
mkdir -p "$OUT"
built=0
for pair in $MODULES; do
    cfg=${pair%%:*}; target=${pair#*:}; name=${target##*/}
    grep -q "^$cfg=m" "$BUILD/.config" || { echo "SKIP $name ($cfg is not =m)"; continue; }
    ( cd "$SRC" && make O=build ARCH=arm64 LLVM=1 -j"$JOBS" "$target" ) || exit 1
    ko="$BUILD/$target"
    [ -f "$ko" ] || { echo "NO_KO $ko"; exit 1; }
    modinfo -F vermagic "$ko"
    install -m 0644 "$ko" "$OUT/$name"
    echo "installed $OUT/$name"
    built=$((built + 1))
done
[ "$built" -gt 0 ] || { echo "nothing built"; exit 1; }