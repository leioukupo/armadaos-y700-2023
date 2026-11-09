#!/bin/sh
# A55: the display chain stays pinned "disabled" in the boot DT exactly as in A52,
# so no MDSS/DSI/GDSC/SMMU code runs.  What is new is in the kernel: y700fb
# (drivers/video/fbdev/y700fb.c) registers an fbdev over the splash buffer ABL is
# still scanning, and it tells the simplefb earlycon to stop drawing so fbcon and
# /dev/fb0 are the only writers.
#
# This script therefore does not touch a single display node.  It answers one
# question, and answers it in a way that is visible on the panel itself:
#
#   1) fb state: /proc/fb, /dev/fb*, /sys/class/graphics/fb0/*, /proc/consoles,
#      /sys/class/vtconsole/* - who owns the console right now;
#   2) does a write to /dev/fb0 land in the memory the panel scans: paint blue,
#      green, red, white, noise, black, 5 s each, and read the first bytes back;
#   3) every step is echoed to kmsg and into y700-a55-step.txt before it happens,
#      so even if the board dies afterwards the card says which colour was the
#      last thing on the screen.
#
# On the panel the expected sequence is: earlycon log (frozen when y700fb takes
# over) -> penguin logo + real text console -> solid blue -> green -> red ->
# white -> noise -> black -> lime.  Any solid colour at all means Linux, not ABL,
# drives the scanout.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K='Y700-A55'
R=/mnt/card/y700-a55-report.txt
T=/mnt/card/y700-a55-kmsg.txt
S=/mnt/card/y700-a55-step.txt
BLK=/tmp/y700-a55-blk
NODE=/sys/kernel/debug/y700-node

m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
w() { echo "$*" >> "$R" 2>/dev/null; }
F() { sync; sync; }
UP() { cut -d. -f1 /proc/uptime; }
LS() { ls -d $@ 2>/dev/null | busybox tr '\n' ' '; }
step() { echo "$1 up=$(UP)" > "$S" 2>/dev/null; F; m "STEP $1"; }

# build one 4096-byte block of a solid colour.  The splash is a8r8g8b8, which in
# memory is B,G,R,A, so the octal escapes below are byte order, not pixel order.
mkblk() {
	: > "$BLK"
	i=0
	while [ $i -lt 1024 ] ; do
		printf "$1" >> "$BLK"
		i=$((i + 1))
	done
}

paint() {
	# $1 = name, $2 = 4 octal escapes
	mkblk "$2"
	step "paint-$1"
	dd if="$BLK" of=/dev/fb0 bs=4096 count="$NBLK" 2>>"$R"
	w "paint $1 rc=$? up=$(UP)"
	F
	sleep 5
}

mount -t debugfs none /sys/kernel/debug 2>/dev/null
echo "===== Y700-A55 fbdev over the ABL splash =====" > "$R" 2>/dev/null
if [ ! -e "$R" ] ; then
	echo "A55 NOCARD cannot write $R"
	exit 4
fi
w "kernel=$(uname -r) up=$(UP) board=Y700-TB320FC"
w "cmdline=$(cat /proc/cmdline)"
F
step "baseline"

( cat /dev/kmsg > "$T" 2>/dev/null ) &
TEE=$!
( while : ; do sleep 2; sync; done ) &
SYNCD=$!
m "TEE=$TEE SYNC=$SYNCD up=$(UP)"

# ---- backlight: never let it dim, the panel has to stay lit ---------------
for b in /sys/class/backlight/* ; do
	[ -f "$b/max_brightness" ] || continue
	mx=$(cat "$b/max_brightness" 2>/dev/null)
	w "backlight $(basename $b) $(cat "$b/brightness" 2>/dev/null)/${mx:-none}"
	[ -n "$mx" ] && echo "$mx" > "$b/brightness" 2>/dev/null
done
F

# ---- who owns the panel --------------------------------------------------
w ""
w "== fb state =="
w "procfb=$(cat /proc/fb 2>/dev/null | busybox tr '\n' '|') devfb=$(LS /dev/fb0 /dev/fb1)"
w "consoles=$(cat /proc/consoles | busybox tr '\n' '|')"
for v in /sys/class/vtconsole/vtcon* ; do
	[ -d "$v" ] || continue
	w "vtcon $(basename $v) name=$(cat $v/name 2>/dev/null | busybox tr -d '\n') state=$(cat $v/state 2>/dev/null) bind=$(cat $v/bind 2>/dev/null)"
done
w "drm=$(LS /sys/class/drm/card*) graphics=$(LS /sys/class/graphics/fb*)"
for f in name state mmio virtual_size xres yres xres_virtual yres_virtual stride bits_per_pixel; do
	w "fb0.$f=$(cat /sys/class/graphics/fb0/$f 2>/dev/null | busybox tr -d '\n')"
done
w "modes=$(busybox tr '\n' '|' < /sys/class/graphics/fb0/modes 2>/dev/null)"
w "nodes=$(cat $NODE 2>/dev/null | busybox tr '\n' '|')"
w "deferred=$(busybox tr '\n' '|' < /sys/kernel/debug/devices_deferred 2>/dev/null | cut -c 1-300)"
F

# the driver must have said hello; if it did not, everything below is expected
# to fail and the panel is still ABL's.
w ""
w "== y700fb beacon =="
w "kmsgfb=$(dmesg 2>/dev/null | busybox grep 'Y700-FB' | busybox tr '\n' '|')"
F

if [ ! -e /dev/fb0 ] ; then
	w "RESULT no /dev/fb0 - y700fb never registered, panel still ABL's"
	step "no-fb0"
	m "RESULT no-fb0"
	F
	w "END up=$(UP)"
	F
	exit 0
fi

VS=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)
X=${VS% *}
Y=${VS#* }
SZ=$((X * Y * 4))
NBLK=$((SZ / 4096))
w "geometry ${X}x${Y} bytes=$SZ blocks=$NBLK"
if [ "$NBLK" -lt 1 ] ; then
	w "RESULT bad geometry, refusing to paint"
	step "bad-geometry"
	exit 0
fi

# ---- the actual test: seven screens, one colour each ----------------------
w ""
w "== paint (5 s each) =="
paint blue  '\377\000\000\000'
paint green '\000\377\000\000'
paint red   '\000\000\377\000'
paint white '\377\377\377\000'

step "paint-noise"
dd if=/dev/urandom of=/dev/fb0 bs=4096 count="$NBLK" 2>>"$R"
w "paint noise rc=$? up=$(UP)"
F
sleep 5

# read the first bytes back: they must still be the noise, which proves the fb is
# ordinary memory this kernel can both write and read.
w "readback=$(dd if=/dev/fb0 bs=16 count=1 2>/dev/null | busybox hexdump -v -e '4/1 "%02x"')"

paint black '\000\000\000\000'
paint lime  '\000\377\377\000'

# leave the panel on a solid colour so a photograph taken at any later moment
# still answers the question.
step "done"
w "RESULT painted 7 screens, fb0=${X}x${Y}32, consoles=$(cat /proc/consoles | busybox tr '\n' '|')"
w "END up=$(UP)"
m "END up=$(UP) fb=${X}x${Y}"
F
