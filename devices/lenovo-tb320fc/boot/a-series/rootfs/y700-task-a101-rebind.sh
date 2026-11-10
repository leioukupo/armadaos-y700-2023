#!/bin/sh
# A101: touch input never reaches userspace, so start looking at the driver.
#
# A100 settled two things.  The userspace chain is now correct: the republished
# "Y700 Touchscreen (rotated)" is tagged by udev as Touchscreen and weston says
# "device is a touch device" (BTN_TOOL_FINGER gone, ID_INPUT_TOUCHPAD cleared).
# But the forwarder read ZERO bytes from /dev/input/event2 in a whole session -
# no TOUCH lines, not even the 30 s heartbeat - and /proc/interrupts shows
#
#   131: 0 ... msmgpio 21 Edge  spi0.0
#
# i.e. the NVT interrupt has never fired, while gpio20 (reset) is out-high
# (released) and gpio21 reads in-low with a pull-up.  The driver in this kernel
# is the asphalt one (dev_name(dev) as the irq action name, "finger input
# ready", "validated firmware"), and it is a drm_panel_follower.  Our DTB points
# touchscreen@0 at the A70 *stub* panel, so its firmware host-download ran at
# 3.16 s - before the real DSI panel was prepared at 3.94 s.  For an in-cell
# panel the digitizer only reports once the display engine is running, so A101
# re-runs that bring-up with the panel provably streaming: unbind + bind
# spi0.0 after weston is up, then start the forwarder.  No reflash, DTB stays.
#
# A99 proved the chain almost works: the forwarder grabbed the NT36523N, made
# "Y700 Touchscreen (rotated)" (event4), and weston configured it.  But weston
# logged "is tagged by udev as: Touchpad Touchscreen" then "device is a
# touchpad" - because the uinput device declared BTN_TOOL_FINGER, which is
# exactly what udev input_id uses for ID_INPUT_TOUCHPAD, and libinput prefers
# the touchpad tag.  The raw event2 was stripped of ID_INPUT at the same time,
# so the desktop had no touchscreen at all.  A101 declares BTN_TOUCH only,
# keeps the touchpad tag cleared, and gives the axes a resolution so libinput
# stops guessing 69x50mm for the device.
#
# Second unknown, settled in the same boot: has the panel ever reported a touch
# to userspace?  A98/A99 captured 0 samples both times.  The driver boots its
# firmware over SPI ("finger input ready") and does
# request_threaded_irq(gpio_to_irq(novatek,irq-gpio = tlmm 21)), so the real
# question is whether that IRQ ever fires.  The forwarder now logs every touch
# down it sees, and the session snapshots /proc/interrupts and
# /sys/kernel/debug/gpio on either side of the weston window.
#
# A98 put [input-device] output=/calibration_matrix= into weston.ini.  The
# weston.ini(5) manual for the weston in this root (libweston-15.so.0.0.1) lists
# only core/libinput/shell/launcher/output/input-method/keyboard/terminal/
# xwayland/screen-share/autolaunch - there is no input-device section, so weston
# ignored both keys and the touchscreen stayed in panel space.  Its calibration
# is a runtime protocol (weston_compositor_enable_touch_calibrator plus a
# calibrator client) and this root ships no calibrator client.
#
# A101 rotates below weston instead: a python3 evdev -> uinput forwarder
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
K="Y700-A101-REBIND"
CARD=/mnt/card
OUT=$CARD/y700-a101-patch.txt
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
# use_rot=0 hands the raw device straight back to weston (no forwarder at all)
if [ ! -e "$TOUCH" ] || ! grep -q "rebind=" "$TOUCH"; then
	{
		echo "rotate=90"
		echo "capture=0"
		echo "grab=1"
		echo "flipx=0"
		echo "flipy=0"
		echo "use_rot=1"
		echo "window=420"
		echo "rebind=1"
	} > "$TOUCH"
fi
m "touch knobs: $(tr '\n' ';' < "$TOUCH" 2>/dev/null)"

echo "=== Y700-A101 patch up=$(UP) ===" > "$OUT" 2>/dev/null
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
import fcntl, glob, os, select, struct, sys, time

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT, SYN_DROPPED = 0x00, 0x01
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_X, ABS_MT_Y = 0x2F, 0x35, 0x36
ABS_MT_TRACKING_ID = 0x39
# BTN_TOOL_FINGER is deliberately absent: udev input_id turns it into
# ID_INPUT_TOUCHPAD, and libinput then treats the touchscreen as a touchpad.
BTN_TOUCH = 0x14A
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
            f.write("<3>Y700-A101 %s\n" % msg)
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


def evbit(fd, ev, nbytes):
    # EVIOCGBIT(ev, len) = _IOC(_IOC_READ, 'E', 0x20 + ev, len)
    cmd = (2 << 30) | (nbytes << 16) | (0x45 << 8) | (0x20 + ev)
    buf = bytearray(nbytes)
    try:
        fcntl.ioctl(fd, cmd, buf)
    except OSError:
        return []
    b, bits = bytes(buf), []
    for i in range(len(b) * 8):
        if b[i // 8] & (1 << (i % 8)):
            bits.append(i)
    return bits


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


def abs_setup(fd, code, lo, hi, res=0):
    # struct uinput_abs_setup = u16 code + u16 padding + input_absinfo
    for size, fmt in ((28, "@2H6i"), (32, "@2H7i")):
        cmd = (1 << 30) | (size << 16) | (0x55 << 8) | UI_ABS_NR
        try:
            if size == 28:
                fcntl.ioctl(fd, cmd, struct.pack(fmt, code, 0, 0, lo, hi, 0, 0, res))
            else:
                fcntl.ioctl(fd, cmd, struct.pack(fmt, code, 0, 0, lo, hi, 0, 0, res, 0))
            return True
        except OSError:
            continue
    return False


def make_out(name, xmax, ymax):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for bit in (EV_SYN, EV_KEY, EV_ABS):
        fcntl.ioctl(fd, UI_SET_EVBIT, bit)
    for key in (BTN_TOUCH,):
        fcntl.ioctl(fd, UI_SET_KEYBIT, key)
    # resolution = 10 units per mm: the driver reports 10x the panel pixels
    axes = ((ABS_MT_SLOT, 0, MAX_SLOT - 1, 0), (ABS_MT_X, 0, xmax, 10),
            (ABS_MT_Y, 0, ymax, 10), (ABS_MT_TRACKING_ID, -1, 1023, 0))
    for code, lo, hi, res in axes:
        fcntl.ioctl(fd, UI_SET_ABSBIT, code)
    # struct uinput_setup = input_id(4 x u16) + name[80] + ff_effects_max = 92 B
    fcntl.ioctl(fd, UI_DEV_SETUP,
                struct.pack("@4H80sI", 0x0018, 0x0001, 0x0001, 0x0100,
                            name.encode()[:79], 0))
    for code, lo, hi, res in axes:
        if not abs_setup(fd, code, lo, hi, res):
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
    log("src keys=%s" % ",".join(hex(x) for x in evbit(fdi, EV_KEY, 96)))
    log("src abs=%s" % ",".join(hex(x) for x in evbit(fdi, EV_ABS, 8)))
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
        live.pop(s, None)
        published.discard(s)


    slot = 0
    nev = ndown = nframe = nread = 0
    beat = time.time()
    pos = {}
    live = {}
    published = set()
    down = False
    nxt = 0
    while True:
        if time.time() - beat >= 30:
            beat = time.time()
            log("listening: reads=%d bytes=%d frames=%d downs=%d" %
                (nread, nev, nframe, ndown))
        try:
            ready = select.select([fdi], [], [], 1.0)[0]
        except OSError:
            time.sleep(0.2)
            continue
        if not ready:
            continue
        nread += 1
        try:
            data = os.read(fdi, 256 * IEV.size)
        except OSError:
            time.sleep(0.01)
            continue
        nev += len(data) // IEV.size
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
                nframe += 1
                for s in sorted(live):
                    xy = pos.get(s)
                    if not xy or xy[0] is None or xy[1] is None:
                        continue
                    X, Y = tr(xy[0], xy[1])
                    emit(fdo, EV_ABS, ABS_MT_SLOT, s)
                    if s not in published:
                        emit(fdo, EV_ABS, ABS_MT_TRACKING_ID, live[s])
                        published.add(s)
                        ndown += 1
                        if ndown <= 40:
                            log("TOUCH %d raw=%d,%d out=%d,%d" %
                                (ndown, xy[0], xy[1], X, Y))
                            kmsg("TOUCH %d raw=%d,%d out=%d,%d" %
                                 (ndown, xy[0], xy[1], X, Y))
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

# udev tags are what libinput reads, so both variants ship in the root and the
# session copies one of them into rules.d (knob use_rot= on the card).
mkdir -p "$R/etc/udev/rules.d"
# the raw node name is "NT36523N Capacitive Touchscreen" (weston log event2)
cat > "$R/var/lib/y700/rawtouch-hide.rules" <<'RU'
# use_rot=1: y700-touch-rot.py republishes the panel, so hide the raw node and
# keep the republished one a touchscreen (never a touchpad).
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NT36523N Capacitive Touchscreen", ENV{ID_INPUT}="", ENV{ID_INPUT_TOUCHSCREEN}="", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_KEYBOARD}=""
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="*rotated*", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1", ENV{ID_INPUT_TOUCHPAD}="", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_KEYBOARD}=""
RU
cat > "$R/var/lib/y700/rawtouch-show.rules" <<'RU'
# use_rot=0: no forwarder, weston reads the panel device directly.
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NT36523N Capacitive Touchscreen", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1", ENV{ID_INPUT_TOUCHPAD}=""
RU
rm -f "$R/etc/udev/rules.d/99-y700-rawtouch.rules"
U "udev variants installed (hide + show)"

# ---------- the session ----------
cat > "$R/usr/local/sbin/y700-taptext.sh" <<'TAP'
#!/bin/sh
# shown in the terminal window: what to touch, and in which order
echo "Y700 A101 TOUCH TEST"
echo
echo "touch restarts when this window appears -"
echo "if nothing moves, keep tapping anyway"
echo
echo "TAP 1  CENTRE OF THE SCREEN"
echo "TAP 2  TOP-LEFT CORNER"
echo "TAP 3  TOP-RIGHT CORNER"
echo "TAP 4  BOTTOM-RIGHT CORNER"
echo "TAP 5  BOTTOM-LEFT CORNER"
echo "TAP 6  ANY KEY IF A KEYBOARD POPS UP"
echo
echo "keep tapping for four minutes"
sleep 100000
TAP
chmod 0755 "$R/usr/local/sbin/y700-taptext.sh"
U "tap-test text installed"

cat > "$R/usr/local/sbin/y700-desktop.sh" <<'DESK'
#!/bin/sh
# A101: capture the raw panel coordinates first (weston is not running yet, so
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
T=/tmp/y700-a101-desktop.txt
ROT=/usr/local/sbin/y700-touch-rot.py
mirror() {
	cp "$T" "$SPOOLD/desktop.txt" 2>/dev/null
	cp "$SPOOLD/rotator.txt" "$SPOOLD/rotator-copy.txt" 2>/dev/null
	sync
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a101-desktop.txt" 2>/dev/null
	cp "$SPOOLD/rotator.txt" "$C/y700-a101-rotator.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A101 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A101 $*" >> "$T" 2>/dev/null
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
tirq() { awk '$NF=="spi0.0" {print $2}' /proc/interrupts 2>/dev/null; }
irqsnap() {
	{
		echo "-- interrupts $1 up=$(cut -d. -f1 /proc/uptime) --"
		cat /proc/interrupts 2>/dev/null | head -120
		echo "-- gpio $1 --"
		cat /sys/kernel/debug/gpio 2>/dev/null | head -60
	} >> "$T" 2>&1
	mirror
}
echo "===== Y700-A101 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} =====" >> "$T" 2>&1

# knobs: card wins, root copy is the fallback for cardless boots
if [ -n "$CARD" ] && [ -e "$C/y700-touch.txt" ]; then
	cp "$C/y700-touch.txt" $SPOOLD/touch-rot.txt 2>/dev/null
fi
[ -e $SPOOLD/touch-rot.txt ] || { echo "rotate=90" > $SPOOLD/touch-rot.txt; echo "capture=20" >> $SPOOLD/touch-rot.txt; echo "grab=1" >> $SPOOLD/touch-rot.txt; }
ROTVAL=$(awk -F= '/^rotate=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
FXVAL=$(awk -F= '/^flipx=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
FYVAL=$(awk -F= '/^flipy=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
CAPT=$(awk -F= '/^capture=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
USEROT=$(awk -F= '/^use_rot=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
WVAL=$(awk -F= '/^window=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
[ -n "$ROTVAL" ] || ROTVAL=90
[ -n "$CAPT" ] || CAPT=0
[ -n "$USEROT" ] || USEROT=1
[ -n "$WVAL" ] || WVAL=420
REBIND=$(awk -F= '/^rebind=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
[ -n "$REBIND" ] || REBIND=1
m "session knobs rotate=$ROTVAL flipx=${FXVAL:-0} flipy=${FYVAL:-0} use_rot=$USEROT rebind=$REBIND window=${WVAL}s card=${CARD:-none}"

# choose the udev variant before anything opens the panel device
if [ "$USEROT" = "1" ]; then
	cp $SPOOLD/rawtouch-hide.rules /etc/udev/rules.d/99-y700-rawtouch.rules 2>/dev/null
else
	cp $SPOOLD/rawtouch-show.rules /etc/udev/rules.d/99-y700-rawtouch.rules 2>/dev/null
fi
m "udev variant use_rot=$USEROT rules=$(grep -c SUBSYSTEM /etc/udev/rules.d/99-y700-rawtouch.rules 2>/dev/null)"
udevadm control --reload-rules 2>/dev/null
udevadm trigger --subsystem-match=input 2>/dev/null

# ---- phase 1: raw capture, weston still stopped, console still visible ----
: > $SPOOLD/rotator.txt 2>/dev/null
if [ "$CAPT" != "0" ]; then
	{
		echo ""
		echo "<3>==== Y700-A101 TOUCH CALIBRATION ===="
		echo "<3>ROT=${ROTVAL} FX=${FXVAL:-0} FY=${FYVAL:-0} - TOUCH IN THIS ORDER:"
		echo "<3>  1 TOP-LEFT  2 TOP-RIGHT  3 BOTTOM-RIGHT  4 BOTTOM-LEFT  5 CENTRE"
	} > /dev/kmsg 2>/dev/null
	m "capture start secs=${CAPT}"
	timeout $((CAPT + 8)) python3 "$ROT" --capture "$CAPT" >> "$T" 2>&1
	m "capture done, python rc=$?"
fi

# ---- phase 2: what does the kernel think the touch controller is doing? ----
SPIDRV=""
for d in /sys/bus/spi/drivers/*; do
	[ -d "$d" ] || continue
	case "${d##*/}" in
		*nt36523*|*nvt*) SPIDRV=${d##*/} ;;
	esac
done
RP=""
m "spi touch driver=${SPIDRV:-none} irq21=$(tirq)"
{
	echo "-- touch dmesg --"
	dmesg 2>/dev/null | grep -iE "nt36523|nvt|finger input|validated firmware|pen state|spi0.0" | tail -30
} >> "$T" 2>&1

# ---- phase 3: weston ----
WINDOW=${Y700_WINDOW:-$WVAL}
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
irqsnap before

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
	CLI=""
	if [ -x /usr/bin/foot ]; then
		timeout $((WINDOW - 40)) /usr/bin/foot -e /usr/local/sbin/y700-taptext.sh >> "$T" 2>&1 &
		CLI="foot -e y700-taptext.sh"
	elif [ -x /usr/bin/weston-terminal ]; then
		timeout $((WINDOW - 40)) /usr/bin/weston-terminal >> "$T" 2>&1 &
		CLI=weston-terminal
	fi
	m "client launched ${CLI:-nothing}"
fi
{
	echo "-- weston input lines --"
	grep -iE "Touchscreen|rotated|associating input|calibrat|device removed|udev as|not a touch|failed to grab" "$T" 2>/dev/null | tail -30
} >> "$T" 2>&1
survey
# ---- phase 4: NVT bring-up again, this time with the panel streaming ----
IRQ0=$(tirq)
if [ "$REBIND" = "1" ] && [ -n "$SPIDRV" ]; then
	echo spi0.0 > /sys/bus/spi/drivers/$SPIDRV/unbind 2>/dev/null && m "unbound spi0.0 irq21=$(tirq)"
	sleep 2
	echo spi0.0 > /sys/bus/spi/drivers/$SPIDRV/bind 2>/dev/null && m "binding spi0.0"
	i=0
	while [ "$i" -lt 40 ]; do
		sleep 1
		i=$((i + 1))
		dmesg 2>/dev/null | tail -40 | grep -qi "finger input ready" && break
	done
	{
		echo "-- dmesg after rebind up=$(cut -d. -f1 /proc/uptime) --"
		dmesg 2>/dev/null | grep -iE "nt36523|nvt|finger input|validated firmware|pen state|defer|error|fail" | tail -25
	} >> "$T" 2>&1
	m "rebind done after ${i}s irq21=$(tirq) was=${IRQ0:-none}"
else
	m "rebind skipped rebind=$REBIND driver=${SPIDRV:-none}"
fi

# ---- phase 5: the forwarder, on the freshly created panel node ----
if [ ! -c /dev/uinput ]; then
	modprobe uinput 2>/dev/null
	mknod /dev/uinput c 10 223 2>/dev/null
fi
: > $SPOOLD/rotator.txt 2>/dev/null
if [ "$USEROT" = "1" ]; then
	python3 "$ROT" >> "$T" 2>&1 &
	RP=$!
fi
sleep 3
RDEV=""
for e in /sys/class/input/event*; do
	[ -d "$e/device" ] || continue
	case "$(cat $e/device/name 2>/dev/null)" in
		*rotated*) RDEV=${e##*/} ;;
	esac
done
if [ -n "$RP" ] && [ -d /proc/$RP ] && [ -n "$RDEV" ]; then
	m "forwarder up pid=$RP publishes $RDEV tags=$(udevadm info -q property -p /sys/class/input/$RDEV 2>/dev/null | grep ID_INPUT | tr '\n' ',')"
elif [ -n "$RP" ] && [ -d /proc/$RP ]; then
	m "forwarder alive pid=$RP but NO rotated input node"
elif [ -n "$RP" ]; then
	m "forwarder died immediately pid=$RP"
else
	m "forwarder skipped use_rot=0"
fi
m "TAP THE SCREEN NOW: centre then the four corners, keep going for three minutes"
if [ -S $RUN/wayland-1 ]; then
	end=$(( $(cut -d. -f1 /proc/uptime) + WINDOW ))
	tick=0
	while [ -d /proc/$WP ] && [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
		sleep 5
		tick=$((tick + 1))
		[ $((tick % 4)) = 0 ] && mirror
	done
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
if [ -n "$RP" ]; then
	kill -TERM $RP 2>/dev/null
	sleep 1
	kill -KILL $RP 2>/dev/null
fi
irqsnap after
{ echo "-- rotator log --"; cat $SPOOLD/rotator.txt 2>/dev/null | head -80; } >> "$T" 2>&1
m "rotator lines=$(wc -l < $SPOOLD/rotator.txt 2>/dev/null) taps=$(grep -c 'TOUCH ' $SPOOLD/rotator.txt 2>/dev/null) irq21=$(tirq) was=${IRQ0:-none}"
survey
m "session over, PULL THE CARD NOW"
mirror
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v10 installed (rotator + udev variant + irq snapshot)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A101 weston session with a userspace-rotated touchscreen
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
