#!/bin/sh
# A99: rotate the touchscreen in userspace, because weston has no config for it.
#
# A98 put [input-device] output=/calibration_matrix= into weston.ini.  The
# weston.ini(5) manual for the weston in this root (libweston-15.so.0.0.1) lists
# only core/libinput/shell/launcher/output/input-method/keyboard/terminal/
# xwayland/screen-share/autolaunch - there is no input-device section, so weston
# ignored both keys and the touchscreen stayed in panel space.  Its calibration
# is a runtime protocol (weston_compositor_enable_touch_calibrator plus a
# calibrator client) and this root ships no calibrator client.
#
# A99 rotates below weston instead: a python3 evdev -> uinput forwarder
# re-publishes the NT36523N with ABS ranges that already match the rotated
# desktop, so weston's linear mapping becomes the identity.  The root is Armada
# (Fedora 44 base) with python3.14, evtest, tslib and inputplumber, and the
# vendor kernel has CONFIG_INPUT_UINPUT=y.  Nothing else remaps this panel
# (inputplumber only profiles Legion Go / tb322fc / tb323fu), so the forwarder
# is the only one in the chain.
#
# Why rotate=90: weston transform=rotate-270 puts a plane "rotation=270 CW" on a
# 1600x2560 mode, so a logical point (X,Y) of the 2560x1600 desktop lands at
# panel (x=Y, y=2559-X); inverting gives X=2559-y, Y=x, which is tr() with
# rot=90.  The driver (drivers/input/touchscreen/novatek-nt36523n-spi.c) reports
# ABS_MT_POSITION_X 0..16000 and ABS_MT_POSITION_Y 0..25600, i.e. 10x the panel,
# with input_mt_slot()/ABS_MT_TRACKING_ID plus BTN_TOUCH - so ranges scale
# themselves and release detection comes from the tracking id.
#
# Ground truth first: the capture phase runs while weston is still down, so the
# evdev node is free (A98 read it after weston had grabbed it, which is why
# y700-a98-ev.raw was 0 bytes).  Rotation lives in y700-touch.txt on the card and
# is copied into the root at every session start, so a wrong rotation is a
# one-line edit plus a reboot - no re-patch, no reflash.  boot_b stays on A96.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A99-TOUCHROT"
CARD=/mnt/card
OUT=$CARD/y700-a99-patch.txt
TOUCH=$CARD/y700-touch.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "$K $*"; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
m "GO root=$RD up=$(UP)"
case "$RD" in
	*/sda16) m "REFUSE we are booted off $RD, the very partition to patch"; exit 1 ;;
esac

# A98 left associate=/matrix=/capture= here; the forwarder wants other keys
[ -e "$TOUCH" ] && grep -q "rotate=" "$TOUCH" && : || rm -f "$TOUCH"
if [ ! -e "$TOUCH" ]; then
	{
		echo "rotate=90"
		echo "capture=30"
		echo "grab=1"
		echo "flipx=0"
		echo "flipy=0"
	} > "$TOUCH"
fi
m "touch knobs: $(tr '\n' ';' < "$TOUCH" 2>/dev/null)"

echo "=== Y700-A99 patch up=$(UP) ===" > "$OUT" 2>/dev/null
U "rootdev=$RD"
[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
i=0
while [ ! -e /sys/block/sda/sda16 ] && [ "$i" -lt 90 ]; do
	sleep 5
	i=$((i + 5))
	m "ufs wait ${i}s"
done
U "ufs wait i=$i"
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; exit 1; }

MSG=$(mount -t ext4 -o rw /dev/sda16 /mnt/ufs 2>&1)
MR=$?
U "mount rw rc=$MR msg=$MSG"
[ "$MR" = "0" ] || { m "REFUSE cannot mount sda16 rw"; exit 1; }
R=/mnt/ufs
[ -x "$R/usr/bin/weston" ] || { m "REFUSE no weston in root"; umount /mnt/ufs; exit 1; }
[ -x "$R/usr/bin/python3" ] || { m "REFUSE no python3 in root"; umount /mnt/ufs; exit 1; }
mkdir -p "$R/usr/local/sbin" "$R/var/lib/y700" "$R/etc/udev/rules.d" "$R/etc/systemd/system/multi-user.target.wants"

cat > "$R/usr/local/sbin/y700-touch-rot.py" <<PYEOF
#!/usr/bin/python3
import fcntl, glob, os, struct, sys, time

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT, SYN_DROPPED = 0x00, 0x01
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_X, ABS_MT_Y = 0x2F, 0x35, 0x36
ABS_MT_TRACKING_ID = 0x39
BTN_TOOL_FINGER, BTN_TOUCH = 0x145, 0x14A
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_DEV_SETUP, UI_DEV_CREATE = 0x405C5503, 0x5501
UI_ABS_NR = 4
EVIOCGRAB = 0x40044590
IEV = struct.Struct("@qqHHi")
CARD_CFG = "/mnt/y700card/y700-touch.txt"
ROOT_CFG = "/var/lib/y700/touch-rot.txt"
LOGF = "/var/lib/y700/rotator.txt"
MAX_SLOT = 10


def log(msg):
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    try:
        with open(LOGF, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def kmsg(msg):
    try:
        with open("/dev/kmsg", "w") as f:
            f.write("<3>Y700-A99 %s\n" % msg)
    except OSError:
        pass


def rd(path):
    try:
        return open(path, "r").read().strip()
    except OSError:
        return ""


def cfg():
    out = {"rotate": "90", "capture": "0", "grab": "1", "src": "",
           "flipx": "0", "flipy": "0"}
    for p in (CARD_CFG, ROOT_CFG):
        if not os.path.exists(p):
            continue
        for line in rd(p).splitlines():
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() in out:
                out[k.strip()] = v.strip()
    return out


def sources(want):
    out = []
    for p in sorted(glob.glob("/dev/input/event*")):
        n = os.path.basename(p)
        if want and n != want:
            continue
        name = rd("/sys/class/input/%s/device/name" % n)
        caps = rd("/sys/class/input/%s/device/capabilities/abs" % n)
        if "rotated" in name.lower():
            continue
        low = name.lower()
        if ("Touchscreen" in name or "touch" in low or "nt36523" in low or
                "nvt36" in low or name in ("in-cell",)):
            out.append((p, n, name, caps))
    return out


def rng(fd, code):
    # EVIOCGABS(n) = _IOC(_IOC_READ, 'E', 0x40 + n, sizeof(struct input_absinfo))
    for size, fmt in ((28, "@7i"), (24, "@6i")):
        cmd = (2 << 30) | (size << 16) | (0x45 << 8) | (0x40 + code)
        try:
            buf = bytearray(size)
            fcntl.ioctl(fd, cmd, buf)
            v = struct.unpack(fmt, bytes(buf))
        except OSError:
            continue
        if v[2] > v[1]:
            return (v[1], v[2])
    return None


def abs_setup(fd, code, lo, hi):
    # struct uinput_abs_setup = u16 code + u16 padding + input_absinfo
    for size, fmt in ((28, "@2H6i"), (32, "@2H7i")):
        cmd = (1 << 30) | (size << 16) | (0x55 << 8) | UI_ABS_NR
        try:
            if size == 28:
                fcntl.ioctl(fd, cmd, struct.pack(fmt, code, 0, 0, lo, hi, 0, 0, 0))
            else:
                fcntl.ioctl(fd, cmd, struct.pack(fmt, code, 0, 0, lo, hi, 0, 0, 0, 0))
            return True
        except OSError:
            continue
    return False


def make_out(name, xmax, ymax):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for bit in (EV_SYN, EV_KEY, EV_ABS):
        fcntl.ioctl(fd, UI_SET_EVBIT, bit)
    for key in (BTN_TOOL_FINGER, BTN_TOUCH):
        fcntl.ioctl(fd, UI_SET_KEYBIT, key)
    axes = ((ABS_MT_SLOT, 0, MAX_SLOT - 1), (ABS_MT_X, 0, xmax),
            (ABS_MT_Y, 0, ymax), (ABS_MT_TRACKING_ID, -1, 1023))
    for code, lo, hi in axes:
        fcntl.ioctl(fd, UI_SET_ABSBIT, code)
    # struct uinput_setup = input_id(4 x u16) + name[80] + ff_effects_max = 92 B
    fcntl.ioctl(fd, UI_DEV_SETUP,
                struct.pack("@4H80sI", 0x0018, 0x0001, 0x0001, 0x0100,
                            name.encode()[:79], 0))
    for code, lo, hi in axes:
        if not abs_setup(fd, code, lo, hi):
            log("abs setup failed code=0x%X" % code)
            raise OSError("UI_ABS_SETUP failed")
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd, typ, code, val):
    os.write(fd, IEV.pack(0, 0, typ, code, val))


def main():
    c = cfg()
    cap_on = "--capture" in sys.argv
    if cap_on:
        c["capture"] = sys.argv[sys.argv.index("--capture") + 1]
    rot = int(c["rotate"])
    cands = sources(c["src"])
    if not cands:
        log("no touchscreen input device found")
        return 1
    src, ev, name, caps = cands[0]
    log("src=%s name=%s abs_caps=%s rotate=%s flipx=%s flipy=%s capture=%s grab=%s" %
        (src, name, caps, rot, c["flipx"], c["flipy"], c["capture"], c["grab"]))
    fdi = os.open(src, os.O_RDONLY | os.O_NONBLOCK)
    for code, lbl in ((ABS_X, "ABS_X"), (ABS_Y, "ABS_Y"), (ABS_MT_X, "ABS_MT_X"),
                      (ABS_MT_Y, "ABS_MT_Y")):
        r = rng(fdi, code)
        if r:
            log("src %s range %d..%d" % (lbl, r[0], r[1]))
    rx = rng(fdi, ABS_MT_X) or rng(fdi, ABS_X)
    ry = rng(fdi, ABS_MT_Y) or rng(fdi, ABS_Y)
    if not rx or not ry:
        log("no ABS ranges, giving up")
        return 1
    sxmin, sxmax = rx
    symin, symax = ry
    Sx = sxmax - sxmin + 1
    Sy = symax - symin + 1
    dx, dy = (Sy, Sx) if rot in (90, 270) else (Sx, Sy)

    # the 8 elements of the dihedral group: rotate, then flip in the box
    fx = c["flipx"] == "1"
    fy = c["flipy"] == "1"

    def tr(x, y):
        u, v = x - sxmin, y - symin
        if rot == 90:
            X, Y = (Sy - 1) - v, u
        elif rot == 180:
            X, Y = (Sx - 1) - u, (Sy - 1) - v
        elif rot == 270:
            X, Y = v, (Sx - 1) - u
        else:
            X, Y = u, v
        if fx:
            X = (dx - 1) - X
        if fy:
            Y = (dy - 1) - Y
        return X, Y

    log("src %dx%d -> dst %dx%d" % (Sx, Sy, dx, dy))

    cap = int(c["capture"]) if cap_on else 0
    if cap:
        log("capture mode: touch the physical corners, then the centre")
        t0 = time.time()
        beat = 0
        pts, seen, n = [], 0, 0
        while time.time() - t0 < cap:
            if time.time() - beat >= 5:
                beat = time.time()
                left = int(t0 + cap - time.time())
                kmsg("CAPTURE %ds left - TOUCH THE 4 CORNERS THEN CENTRE (seen=%d)" % (left, seen))
            try:
                data = os.read(fdi, 256 * IEV.size)
            except OSError:
                time.sleep(0.02)
                continue
            for i in range(0, len(data) - IEV.size + 1, IEV.size):
                _, _, typ, code, val = IEV.unpack(data[i:i + IEV.size])
                if typ == EV_ABS and code in (ABS_MT_X, ABS_X):
                    pts.append(("x", val))
                elif typ == EV_ABS and code in (ABS_MT_Y, ABS_Y):
                    pts.append(("y", val))
                elif typ == EV_SYN and code == SYN_REPORT and pts:
                    xs = [v for k, v in pts if k == "x"]
                    ys = [v for k, v in pts if k == "y"]
                    if xs and ys:
                        X, Y = tr(xs[-1], ys[-1])
                        if seen < 8:
                            log("raw %5d %5d -> out %5d %5d" % (xs[-1], ys[-1], X, Y))
                            kmsg("TOUCH %d raw %d %d -> rotated %d %d" %
                                 (seen + 1, xs[-1], ys[-1], X, Y))
                        seen += 1
                    n += 1
                    pts = []
                elif typ == EV_SYN and code == SYN_DROPPED:
                    log("SYN_DROPPED during capture")
                    pts = []
        log("capture finished samples=%d frames=%d" % (seen, n))
        return 0

    fdo = make_out("Y700 Touchscreen (rotated)", dx - 1, dy - 1)
    log("uinput up: xmax=%d ymax=%d slots=%d" % (dx - 1, dy - 1, MAX_SLOT))
    if c["grab"] == "1":
        try:
            fcntl.ioctl(fdi, EVIOCGRAB, 1)
            log("source grabbed")
        except OSError as e:
            log("grab failed: %s" % e)
    time.sleep(1.5)

    def release(s):
        pos.pop(s, None)
        if s not in live:
            return
        emit(fdo, EV_ABS, ABS_MT_SLOT, s)
        emit(fdo, EV_ABS, ABS_MT_TRACKING_ID, -1)
        emit(fdo, EV_KEY, BTN_TOOL_FINGER, 0)
        live.pop(s, None)
        published.discard(s)


    slot = 0
    pos = {}
    live = {}
    published = set()
    down = False
    nxt = 0
    while True:
        try:
            data = os.read(fdi, 256 * IEV.size)
        except OSError:
            time.sleep(0.01)
            continue
        for i in range(0, len(data) - IEV.size + 1, IEV.size):
            _, _, typ, code, val = IEV.unpack(data[i:i + IEV.size])
            if typ == EV_ABS and code == ABS_MT_SLOT:
                slot = val if 0 <= val < MAX_SLOT else 0
            elif typ == EV_ABS and code in (ABS_MT_X, ABS_X):
                pos.setdefault(slot, [None, None])[0] = val
            elif typ == EV_ABS and code in (ABS_MT_Y, ABS_Y):
                pos.setdefault(slot, [None, None])[1] = val
            elif typ == EV_ABS and code == ABS_MT_TRACKING_ID:
                if val < 0:
                    release(slot)
                elif slot not in live:
                    live[slot] = nxt
                    nxt = nxt + 1
                    pos.setdefault(slot, [None, None])
            elif typ == EV_KEY and code == BTN_TOUCH and not val:
                for s in list(live):
                    release(s)
            elif typ == EV_SYN and code == SYN_DROPPED:
                log("SYN_DROPPED on the source")
                pos.clear()
                for s in list(live):
                    release(s)
            elif typ == EV_SYN and code == SYN_REPORT:
                for s in sorted(live):
                    xy = pos.get(s)
                    if not xy or xy[0] is None or xy[1] is None:
                        continue
                    X, Y = tr(xy[0], xy[1])
                    emit(fdo, EV_ABS, ABS_MT_SLOT, s)
                    if s not in published:
                        emit(fdo, EV_ABS, ABS_MT_TRACKING_ID, live[s])
                        emit(fdo, EV_KEY, BTN_TOOL_FINGER, 1)
                        published.add(s)
                    emit(fdo, EV_ABS, ABS_MT_X, X)
                    emit(fdo, EV_ABS, ABS_MT_Y, Y)
                now = bool(published)
                if now != down:
                    emit(fdo, EV_KEY, BTN_TOUCH, 1 if now else 0)
                    down = now
                emit(fdo, EV_SYN, SYN_REPORT, 0)

    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod 0755 "$R/usr/local/sbin/y700-touch-rot.py"
U "forwarder installed bytes=$(wc -c < "$R/usr/local/sbin/y700-touch-rot.py")"
# END

# keep weston away from the un-rotated device: udev clears its input tags
mkdir -p "$R/etc/udev/rules.d"
# the raw node name is "NT36523N Capacitive Touchscreen" (weston log event2)
cat > "$R/etc/udev/rules.d/99-y700-rawtouch.rules" <<'RU'
# A99: the NT36523N is republished rotated by y700-touch-rot.py; hide the raw
# one from libinput so weston only ever sees the rotated device.
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NT36523N Capacitive Touchscreen", ENV{ID_INPUT}="", ENV{ID_INPUT_TOUCHSCREEN}="", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_KEYBOARD}=""
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="*rotated*", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1"
RU
U "udev rule installed (hide raw touchscreen from libinput)"

# ---------- the session ----------
cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A99: capture the raw panel coordinates first (weston is not running yet, so
# the evdev node is free), then start the rotator, then weston.
C=/mnt/y700card
CARD=""
for d in /dev/disk/by-label/ARMADA /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/mmcblk2p1; do
	[ -b "$d" ] || continue
	if mountpoint -q "$C"; then
		CARD="$d"
	else
		mkdir -p "$C"
		mount -o rw "$d" "$C" 2>/dev/null && CARD="$d"
	fi
	[ -n "$CARD" ] && break
done
SPOOLD=/var/lib/y700
mkdir -p $SPOOLD
T=/tmp/y700-a99-desktop.txt
ROT=/usr/local/sbin/y700-touch-rot.py
mirror() {
	cp "$T" "$SPOOLD/desktop.txt" 2>/dev/null
	cp "$SPOOLD/rotator.txt" "$SPOOLD/rotator-copy.txt" 2>/dev/null
	sync
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a99-desktop.txt" 2>/dev/null
	cp "$SPOOLD/rotator.txt" "$C/y700-a99-rotator.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A99 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A99 $*" >> "$T" 2>/dev/null
	mirror
}
survey() {
	{
		echo "-- dri --"; ls -l /dev/dri 2>&1
		for f in /sys/class/drm/card[0-9]*-*; do
			[ -d "$f" ] || continue
			echo "conn ${f##*/} status=$(cat $f/status 2>/dev/null)"
		done
		echo "-- input --"; ls -l /dev/input/by-path 2>/dev/null
		for e in /sys/class/input/event*; do
			[ -d "$e/device" ] || continue
			echo "dev ${e##*/} name=$(cat $e/device/name 2>/dev/null) abs=$(cat $e/device/capabilities/abs 2>/dev/null) tags=$(udevadm info -q property -p "$e" 2>/dev/null | tr '\n' ',')"
		done
	} >> "$T" 2>&1
}
echo "===== Y700-A99 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} =====" >> "$T" 2>&1

# knobs: card wins, root copy is the fallback for cardless boots
if [ -n "$CARD" ] && [ -e "$C/y700-touch.txt" ]; then
	cp "$C/y700-touch.txt" $SPOOLD/touch-rot.txt 2>/dev/null
fi
[ -e $SPOOLD/touch-rot.txt ] || { echo "rotate=90" > $SPOOLD/touch-rot.txt; echo "capture=20" >> $SPOOLD/touch-rot.txt; echo "grab=1" >> $SPOOLD/touch-rot.txt; }
ROTVAL=$(awk -F= '/^rotate=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
FXVAL=$(awk -F= '/^flipx=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
FYVAL=$(awk -F= '/^flipy=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
CAPT=$(awk -F= '/^capture=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
[ -n "$ROTVAL" ] || ROTVAL=90
[ -n "$CAPT" ] || CAPT=0
m "session knobs rotate=$ROTVAL flipx=${FXVAL:-0} flipy=${FYVAL:-0} capture=${CAPT}s card=${CARD:-none}"

# hide the raw panel device from libinput before anything opens it
udevadm control --reload-rules 2>/dev/null
udevadm trigger --subsystem-match=input 2>/dev/null
m "udev reloaded"

# ---- phase 1: raw capture, weston still stopped, console still visible ----
: > $SPOOLD/rotator.txt 2>/dev/null
if [ "$CAPT" != "0" ]; then
	{
		echo ""
		echo "<3>==== Y700-A99 TOUCH CALIBRATION ===="
		echo "<3>ROT=${ROTVAL} FX=${FXVAL:-0} FY=${FYVAL:-0} - TOUCH IN THIS ORDER:"
		echo "<3>  1 TOP-LEFT  2 TOP-RIGHT  3 BOTTOM-RIGHT  4 BOTTOM-LEFT  5 CENTRE"
	} > /dev/kmsg 2>/dev/null
	m "capture start secs=${CAPT}"
	timeout $((CAPT + 8)) python3 "$ROT" --capture "$CAPT" >> "$T" 2>&1
	m "capture done, python rc=$?"
fi

# ---- phase 2: start the rotator so weston only sees rotated coordinates ----
if [ ! -c /dev/uinput ]; then
	modprobe uinput 2>/dev/null
	mknod /dev/uinput c 10 223 2>/dev/null
	m "uinput node created=$([ -c /dev/uinput ] && echo yes || echo no)"
fi
: > $SPOOLD/rotator.txt 2>/dev/null
python3 "$ROT" >> "$T" 2>&1 &
RP=$!
sleep 3
RDEV=""
for e in /sys/class/input/event*; do
	[ -d "$e/device" ] || continue
	case "$(cat $e/device/name 2>/dev/null)" in
		*rotated*) RDEV=${e##*/} ;;
	esac
done
if [ -d /proc/$RP ] && [ -n "$RDEV" ]; then
	m "forwarder up pid=$RP publishes $RDEV abs=$(cat /sys/class/input/$RDEV/device/capabilities/abs 2>/dev/null) tags=$(udevadm info -q property -p /sys/class/input/$RDEV 2>/dev/null | grep ID_INPUT | busybox tr '\n' ',')"
elif [ -d /proc/$RP ]; then
	m "forwarder alive pid=$RP but NO rotated input node"
else
	m "forwarder died immediately pid=$RP"
fi

# ---- phase 3: weston ----
WINDOW=${Y700_WINDOW:-420}
for b in /sys/class/vtconsole/vtcon1/bind; do
	[ -e "$b" ] || continue
	echo 0 > "$b" 2>/dev/null && m "fbcon unbound"
done
for d in /sys/class/backlight/*; do
	[ -e "$d/brightness" ] || continue
	echo 1536 > "$d/brightness" 2>/dev/null && m "backlight ${d##*/} $(cat $d/brightness 2>/dev/null)/$(cat $d/max_brightness 2>/dev/null)"
done
KMS=""
for d in /sys/class/drm/card[0-9]*; do
	[ -d "$d" ] || continue
	case "$(readlink -f "$d/device" 2>/dev/null)" in
		*display-controller*) KMS=${d##*/}; break ;;
	esac
done
[ -n "$KMS" ] || for d in /sys/class/drm/card[0-9]*; do
	[ -d "$d" ] || continue
	KMS=${d##*/}
	break
done
CONN=""
for f in /sys/class/drm/$KMS-*; do
	[ -d "$f" ] || continue
	if [ "$(cat "$f/status" 2>/dev/null)" = "connected" ]; then
		CONN=${f##*/$KMS-}
		break
	fi
done
m "picked card=$KMS connector=${CONN:-none}"

RUN=/run/y700-wayland
mkdir -p $RUN
chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN
export XDG_CONFIG_HOME=$RUN
export WESTON_DISABLE_ABSTRACT_FD=1
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
export TZ=Asia/Shanghai
INI=$RUN/weston.ini
cat > "$INI" <<INIHDR
[core]
xkb-layout=us

[output]
name=${CONN:-DSI-1}
transform=rotate-270

[shell]
background-color=0x204080ff
panel-position=bottom
clock-format=minutes-24h

[libinput]
enable-tap=true
INIHDR
cp "$INI" $RUN/weston/weston.ini 2>/dev/null
cp "$INI" $SPOOLD/weston.ini 2>/dev/null
m "ini written connector=${CONN:-DSI-1} transform=rotate-270 (no input-device keys)"

/usr/bin/weston --config="$INI" --backend=drm --drm-device="$KMS" >> "$T" 2>&1 &
WP=$!
i=0
while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
if [ -S $RUN/wayland-1 ]; then
	m "wayland socket after ${i}s"
else
	m "no wayland socket after ${i}s weston alive=$([ -d /proc/$WP ] && echo yes || echo no)"
fi
export WAYLAND_DISPLAY=wayland-1
if [ -S $RUN/wayland-1 ]; then
	timeout $((WINDOW - 40)) /usr/bin/weston-terminal >> "$T" 2>&1 &
	m "client launched weston-terminal"
fi
{
	echo "-- weston input lines --"
	grep -iE "Touchscreen|rotated|associating input|calibrat|device removed|udev as|not a touch|failed to grab" "$T" 2>/dev/null | tail -30
} >> "$T" 2>&1
survey
m "weston up, rotator pid=$RP - now drag a window"
if [ -S $RUN/wayland-1 ]; then
	end=$(( $(cut -d. -f1 /proc/uptime) + WINDOW ))
	while [ -d /proc/$WP ] && [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do sleep 5; done
	if [ -d /proc/$WP ]; then
		m "window elapsed, stopping weston pid=$WP"
		kill -TERM $WP 2>/dev/null
		sleep 4
		kill -KILL $WP 2>/dev/null
	else
		m "weston exited early pid=$WP up=$(cut -d. -f1 /proc/uptime)"
	fi
	wait $WP 2>/dev/null
fi
kill -TERM $RP 2>/dev/null
sleep 1
kill -KILL $RP 2>/dev/null
{ echo "-- rotator log --"; cat $SPOOLD/rotator.txt 2>/dev/null | head -60; } >> "$T" 2>&1
survey
m "session over, PULL THE CARD NOW"
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v9 installed (capture + uinput rotator + clean ini)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A99 weston session with a userspace-rotated touchscreen
After=seatd.service systemd-user-sessions.service

[Service]
Type=simple
TimeoutStartSec=1800
StandardOutput=journal
StandardError=journal
ExecStart=/usr/local/sbin/y700-desktop.sh

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../y700-desktop.service "$R/etc/systemd/system/multi-user.target.wants/y700-desktop.service"
U "desktop unit v8 wanted by multi-user.target"

sync
umount /mnt/ufs 2>/dev/null || m "umount busy"
echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt"
sync
U "marker y700-ufs.txt=$(cat $CARD/y700-ufs.txt)"
m "SESSION INSTALLED, rebooting in 6s - keep the card in"
sleep 6
busybox reboot -f
m "reboot -f did not happen"
sleep 300
exit 0
# END
