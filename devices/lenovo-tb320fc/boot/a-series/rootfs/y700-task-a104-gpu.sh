#!/bin/sh
# A104: touch works - now stop weston from eating it, and make it the default.
#
# A102 settled the kernel side.  With touchscreen@0 `panel` pointed at the real
# panel@0 (0x7c) the SPI client defers ("why spi0.0: spi: wait for supplier
# .../panel@0"), the panel driver runs its reset + 729 ms DSI init first
# (returned at 3.186 s), and only then does the follower upload the touch
# firmware: finger input ready at 3.806 s.  Result, first time in this port:
#
#   rotator: TOUCH 1 raw=8180,13600 out=12000,8180   (40 presses logged)
#   irq21=3637 was=0                                  (interrupt moves)
#   listening: reads=2547 bytes=11196 frames=2551 downs=107
#
# and with use_rot=0 the user could drag windows, and the orientation was right.
#
# Why the forwarder was the thing that looked broken: weston maps a touch into
# the output *mode* extent (1600x2560 here) and then applies the output
# transform itself.  The forwarder had already swapped the ABS ranges to the
# logical space (25600x16000), so every press squeezed into a strip at one
# corner - hundreds of events, no visible effect.  Raw ranges 0..16000 /
# 0..25600 are the mode extent, so use_rot=0 is not a workaround, it is the
# correct layering: the driver, libinput and weston each rotate once.
#
# Remaining defect from this session: once weston went idle it started its
# screensaver + session lock, and a locked weston delivers no touch to clients -
# which reads exactly like the touch dying again.  A104 turns that off in the
# generated weston.ini ([core] idle-time=0, [shell] locking=false) and makes
# use_rot=0 the default in both the card knob block and the session fallback,
# so a boot without the card keeps the same behaviour.
# A104: the Adreno 730 stack.  weston has been drawing with llvmpipe because
# the DT pinned gpu/gmu/gpucc/adreno-smmu off; A104 un-pins them and ships the
# GPU firmware inside the initramfs of the new boot image, so the blobs are
# findable at probe time - adreno_zap_shader_load() answers -ENOENT for a
# missing zap MDT and a6xx_gpu.c treats anything but -ENODEV as fatal, which
# would take the display card down with the GPU.
#
# This run does three things on the UFS root:
#   * copy the same GPU blobs into usr/lib/firmware, so a later driver rebind
#     can find them without the card;
#   * give the session script a GPU branch - hardware GL when 3d00000.gpu is
#     bound, llvmpipe when it is not, so a failed GPU never costs us the
#     desktop we already have;
#   * log what the kernel says about gpucc/gmu/adreno-smmu/zap.
# Touch, rotation, panel and the no-idle settings stay as A103 left them.
# Rollback: fastboot flash boot_b /tmp/y700/e15/boot-b-a102.img.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A104-GPU"
CARD=/mnt/card
OUT=$CARD/y700-a104-patch.txt
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
		echo "use_rot=0"
		echo "window=420"
		echo "rebind=0"
	} > "$TOUCH"
fi
m "touch knobs: $(tr '\n' ';' < "$TOUCH" 2>/dev/null)"

echo "=== Y700-A104 patch up=$(UP) ===" > "$OUT" 2>/dev/null
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

# ---- GPU firmware for the UFS root: the boot image carries the same blobs in
# its initramfs, this copy is for anything that rebinds the driver later ----
[ -d "$CARD/y700-fw" ] || m "NO $CARD/y700-fw on the card, gpu firmware skipped"
for spec in qcom/a730_sqe.fw:74676 qcom/gmu_gen70000.bin:57272 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.mdt:4044 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.b00:148 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.b01:2236 \
            qcom/sm8475/lenovo/tb320fc/a730_zap.b02:3896; do
	p=${spec%%:*}
	want=${spec##*:}
	src="$CARD/y700-fw/$(basename "$p")"
	[ -f "$src" ] || { m "gpu fw missing $src"; continue; }
	got=$(wc -c < "$src")
	[ "$got" = "$want" ] || { m "gpu fw size $p got=$got want=$want"; continue; }
	mkdir -p "$R/usr/lib/firmware/$(dirname "$p")"
	cp -f "$src" "$R/usr/lib/firmware/$p" || { m "gpu fw cp failed $p"; continue; }
	U "gpu fw $p $got"
done
U "gpu fw installed=$(ls $R/usr/lib/firmware/qcom/a730_sqe.fw $R/usr/lib/firmware/qcom/gmu_gen70000.bin $R/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc/a730_zap.mdt 2>/dev/null | wc -l)/3"

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
            f.write("<3>Y700-A104 %s\n" % msg)
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
echo "Y700 A104 TOUCH TEST"
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
# A104: capture the raw panel coordinates first (weston is not running yet, so
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
T=/tmp/y700-a104-desktop.txt
ROT=/usr/local/sbin/y700-touch-rot.py
mirror() {
	cp "$T" "$SPOOLD/desktop.txt" 2>/dev/null
	cp "$SPOOLD/rotator.txt" "$SPOOLD/rotator-copy.txt" 2>/dev/null
	sync
	[ -n "$CARD" ] || return 0
	mountpoint -q "$C" || { mount -o rw "$CARD" "$C" 2>/dev/null || return 0; }
	cp "$T" "$C/y700-a104-desktop.txt" 2>/dev/null
	cp "$SPOOLD/rotator.txt" "$C/y700-a104-rotator.txt" 2>/dev/null
	sync
}
m() {
	echo "<3>Y700-A104 $*" > /dev/kmsg 2>/dev/null
	echo "Y700-A104 $*" >> "$T" 2>/dev/null
	mirror
}
survey() {
	{
		echo "-- dri --"; ls -l /dev/dri 2>&1
		for f in /sys/class/drm/card[0-9]*-*; do
			[ -d "$f" ] || continue
			echo "conn ${f##*/} status=$(cat $f/status 2>/dev/null)"
		done
		echo "-- gpu --"
		ls /sys/bus/platform/devices/ 2>/dev/null | grep -E '3d00000|3d6a000|3d90000|3da0000'
		for dd in /sys/bus/platform/devices/3d00000.gpu /sys/bus/platform/devices/3d6a000.gmu /sys/bus/platform/devices/3d90000.clock-controller /sys/bus/platform/devices/3da0000.iommu; do
			[ -e "$dd" ] && echo "$(basename $dd) driver=$(readlink "$dd/driver" 2>/dev/null)"
		done
		for dd in /sys/bus/platform/drivers/*; do
			case "${dd##*/}" in
				*adreno*|*gmu*|*gpucc*|*smmu*) echo "drv ${dd##*/}: $(ls "$dd" 2>/dev/null | grep -v '^module$' | tr '\n' ' ')" ;;
			esac
		done
		echo "-- gpu dmesg --"
		dmesg 2>/dev/null | grep -iE "adreno|gmu|gpucc|zap|smmu|3d00000|3d6a000|3da0000|deferred probe" | tail -50
		echo "-- deferred --"
		cat /sys/kernel/debug/devices_deferred 2>/dev/null | head -40
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
echo "===== Y700-A104 session up=$(cut -d. -f1 /proc/uptime) card=${CARD:-none} =====" >> "$T" 2>&1

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
[ -n "$USEROT" ] || USEROT=0
[ -n "$WVAL" ] || WVAL=420
REBIND=$(awk -F= '/^rebind=/{print $2}' $SPOOLD/touch-rot.txt 2>/dev/null)
[ -n "$REBIND" ] || REBIND=0
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
		echo "<3>==== Y700-A104 TOUCH CALIBRATION ===="
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
m "input by-path=$(ls /dev/input/by-path/ 2>/dev/null | tr '\n' ' ')"
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
export TZ=Asia/Shanghai
# A104: hardware GL only if the Adreno really bound.  mesa falls back on its
# own, but weston picks llvmpipe the moment LIBGL_ALWAYS_SOFTWARE is set, so
# the two branches have to be explicit - and a dead GPU must not cost us the
# desktop we already have.
GPUB=""
for dd in 3d00000.gpu 3d6a000.gmu 3d90000.clock-controller 3da0000.iommu; do
	[ -e "/sys/bus/platform/devices/$dd/driver" ] && GPUB="$GPUB $dd"
done
RENDER=""
for r in /dev/dri/renderD*; do
	[ -c "$r" ] && RENDER="$RENDER ${r##*/}"
done
m "gpu bind state:${GPUB:- none} render nodes:${RENDER:- none}"
if [ -c /dev/dri/renderD128 ] && echo "$GPUB" | grep -q '3d00000.gpu'; then
	unset GALLIUM_DRIVER
	unset LIBGL_ALWAYS_SOFTWARE
	export LIBGL_DEBUG=verbose
	GLENV="adreno/freedreno"
else
	export GALLIUM_DRIVER=llvmpipe
	export LIBGL_ALWAYS_SOFTWARE=1
	GLENV="llvmpipe"
fi
m "GL renderer env=$GLENV"
INI=$RUN/weston.ini
cat > "$INI" <<INIHDR
[core]
xkb-layout=us
idle-time=0

[output]
name=${CONN:-DSI-1}
transform=rotate-270

[shell]
locking=false
background-color=0x204080ff
panel-position=bottom
clock-format=minutes-24h

[libinput]
enable-tap=true
INIHDR
cp "$INI" $RUN/weston/weston.ini 2>/dev/null
cp "$INI" $SPOOLD/weston.ini 2>/dev/null
m "ini written connector=${CONN:-DSI-1} transform=rotate-270 idle-time=0 locking=false use_rot=$USEROT gl=$GLENV"
irqsnap before

/usr/bin/weston --config="$INI" --backend=drm --drm-device="$KMS" >> "$T" 2>&1 &
WP=$!
i=0
while [ ! -S $RUN/wayland-1 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
if [ -S $RUN/wayland-1 ]; then
	m "wayland socket after ${i}s"
	GL=$(grep -iE "GL renderer|libdrm|fd_pipe|get_param|backend" "$T" 2>/dev/null | tail -8 | tr '\n' '|')
	m "weston gl report: ${GL:-nothing}"
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
{
	echo "-- touch dmesg after taps up=$(cut -d. -f1 /proc/uptime) --"
	dmesg 2>/dev/null | grep -iE "nt36523|nvt|finger input|validated firmware|pen state|bad packet|recovery|spi0.0" | tail -40
} >> "$T" 2>&1
{ echo "-- rotator log --"; cat $SPOOLD/rotator.txt 2>/dev/null | head -80; } >> "$T" 2>&1
m "rotator lines=$(wc -l < $SPOOLD/rotator.txt 2>/dev/null) taps=$(grep -c 'TOUCH ' $SPOOLD/rotator.txt 2>/dev/null) irq21=$(tirq) was=${IRQ0:-none}"
survey
m "session over, PULL THE CARD NOW"
mirror
# a cardless boot has no card to pull logs off, so keep them in the root too
mkdir -p /var/log 2>/dev/null
cp "$T" /var/log/y700-desktop.txt 2>/dev/null
cp $SPOOLD/rotator.txt /var/log/y700-rotator.txt 2>/dev/null
[ -n "$CARD" ] && umount "$C" 2>/dev/null
exit 0
DESK
chmod 0755 "$R/usr/local/sbin/y700-desktop.sh"
U "desktop script v11 installed (gpu branch + gl env + rotator + udev variant + irq snapshot)"

cat > "$R/etc/systemd/system/y700-desktop.service" <<'UNIT'
[Unit]
Description=Y700 A104 weston session with a userspace-rotated touchscreen
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
