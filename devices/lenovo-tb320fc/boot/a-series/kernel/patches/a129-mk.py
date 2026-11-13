#!/usr/bin/env python3
"""A129: feed the WCN6855 firmware to the probe that runs inside the initcall window.

A126 proved the built-in probe at up=2.6 s is harmless: the endpoint enumerates,
BAR 0 is assigned, MSI is set up, MHI says "Power on setup success", and the only
thing missing is ath11k/WCN6855/hw2.1/amss.bin (error -2, because at that moment
the only /lib/firmware in reach is the initramfs one).  Every probe attempted
after that window - A121 unbind/bind, A128 insmod at up=12..79 - rebooted the
tablet with no output at all.

A122-A124 baked the firmware into the initramfs and the tablet died before the SD
card was even probed, but that round pushed the Image from 57461248 to 60213760
bytes.  A129 buys the same 5.6 MB of firmware back: CONFIG_KALLSYMS_ALL=n is
worth 2752512 bytes and an XZ-compressed embedded cpio another ~930000, which
lands the Image at ~56.5 MB - smaller than the A128 bytes that boot every day.
So this round is also the size test A124 could not run: if A129 boots, the
A122-A124 death was the Image size; if it dies the same way, a powered-up
WCN6855 is what the board cannot tolerate.
"""
import os

A = "/tmp/y700"


def rd(p):
    return open(p, encoding="utf-8", newline="\n").read()


def wr(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w", encoding="utf-8", newline="\n").write(s)


def one(s, a, b, what):
    n = s.count(a)
    if n != 1:
        raise SystemExit("anchor %s found %d times" % (what, n))
    return s.replace(a, b, 1)


# ---------------- 1. the initramfs patch ----------------
t = rd(A + "/a128/patch.sh").replace("A128", "A129").replace("a128", "a129")

# 1a. drop the .ko install step: there is no module any more
KS = '# ---- 4b. A129: ath11k_pci is a module now, so the .ko rides in the initramfs ----'
KE = '\tU "A129 KO MISSING"\nfi\n'
i, j = t.find(KS), t.find(KE)
if i < 0 or j < 0:
    raise SystemExit("KO SECTION SLICE NOT FOUND i=%s j=%s" % (i, j))
t = t[:i] + """# ---- 4b. A129: ath11k_pci is built in again, so there is no .ko to install ----
# A127 shipped ath11k_pci.ko in the initramfs and A128 insmod'd it once the root
# was mounted.  The insmod itself rebooted the tablet, exactly like the A121
# unbind/bind: ath11k_pci_power_up() ends in ath11k_pci_sw_reset(), which runs a
# global reset of the Wi-Fi SoC, and this board does not survive that outside the
# initcall window.  So the driver goes back into the kernel and A129 feeds its
# firmware to that first probe instead.
if [ -e "$R/usr/lib/y700/ath11k_pci.ko" ] ; then
	rm -f "$R/usr/lib/y700/ath11k_pci.ko" 2>/dev/null
	rm -f "$R/var/lib/y700/ath11k-ko.done" 2>/dev/null
	U "A129 removed the stale ath11k_pci.ko from the root"
fi
""" + t[j + len(KE):]

# 1b. script defaults and the conf both stop asking for insmod
n = t.count("rebind=off\ninsmod=on\n")
if n != 1:
    raise SystemExit("script default insmod anchor found %d times" % n)
t = t.replace("rebind=off\ninsmod=on\n", "rebind=off\ninsmod=off\n", 1)
n = t.count("insmod=on\nrebind=off\n")
if n != 1:
    raise SystemExit("conf insmod anchor found %d times" % n)
t = t.replace("insmod=on\nrebind=off\n", "insmod=off\nrebind=off\n", 1)

# 1c. the wifi script body: observe only, there is no load path
BODY_OLD_START = "DEV=$(devfor)\nBOUND=no\n"
BODY_OLD_END = "push\nexit 0\nWIFI"
i, j = t.find(BODY_OLD_START), t.find(BODY_OLD_END)
if i < 0 or j < 0 or j <= i:
    raise SystemExit("WIFI BODY SLICE NOT FOUND i=%s j=%s" % (i, j))
BODY_NEW = r"""DEV=$(devfor)
BOUND=no
[ -n "$DEV" ] && [ -e "$DRV/$DEV" ] && BOUND=yes
L "start up=$(upt) dev=${DEV:-none} drv=$([ -d "$DRV" ] && echo present || echo absent) bound=$BOUND builtin=yes net=[$(netlist)]"
L "start fw=[$(ls /usr/lib/firmware/ath11k/WCN6855/hw2.1 2>/dev/null | tr '\n' ',')] regdb=$([ -e /usr/lib/firmware/regulatory.db ] && echo present || echo absent)"
L "start uname=$(uname -r) modules=[$(awk '{print $1}' /proc/modules 2>/dev/null | tr '\n' ',')] phy=[$(ls /sys/class/ieee80211 2>/dev/null | tr '\n' ',')]"
# A129 states the whole situation before it touches the card: A128 proved that a
# session can end between two pushes, so the decision line has to be readable on
# its own.  There is no load branch: ath11k_pci is built in and was probed at
# up=2.6 s, which A126 showed is the only window this board tolerates.
L "decision drv=$([ -d "$DRV" ] && echo present || echo absent) bound=$BOUND dev=${DEV:-none} conf_insmod=$insmod regdom=$regdom regdb=$([ -e /usr/lib/firmware/regulatory.db ] && echo present || echo absent)"
push
L "mark mirror-1 done"
if [ "$insmod" = on ] ; then
	L "load skip: ath11k_pci is built in this round, conf insmod=$insmod is ignored"
fi

if wlan >/dev/null ; then
	I=$(wlan)
	timeout 15 ip link set "$I" up 2>>"$LOG"
	[ -n "$regdom" ] && timeout 15 iw reg set "$regdom" 2>>"$LOG"
	sleep 3
	L "RESULT wifi-up iface=$I mac=$(cat "/sys/class/net/$I/address" 2>/dev/null) mtu=$(cat "/sys/class/net/$I/mtu" 2>/dev/null) operstate=$(cat "/sys/class/net/$I/operstate" 2>/dev/null) flags=[$(ip -o link show "$I" 2>/dev/null | cut -d ' ' -f 3)] wireless=$([ -d "/sys/class/net/$I/wireless" ] && echo yes || echo no)"
	L "RESULT reg=[$(iw reg get 2>/dev/null | head -2 | tr '\n' ' ')]"
	L "RESULT channels=$(timeout 20 iw phy phy0 info 2>/dev/null | grep -c '^\t\* [0-9]')"
	L "RESULT ssids=$(timeout 40 iw dev "$I" scan 2>/dev/null | grep -c '^SSID: ')"
	L "RESULT scanrc=$?"
else
	L "RESULT no-wlan bound=$BOUND drv=$([ -d "$DRV" ] && echo present || echo absent) net=[$(netlist)]"
	L "RESULT drvlinks=[$(ls "$DRV" 2>/dev/null | tr '\n' ',')]"
fi
L "RESULT rfkill=[$(rfkill list 2>/dev/null | tr '\n' ',')]"
L "RESULT nm=[$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr '\n' ',')]"
L "RESULT kvtail $(kvtail)"
push
exit 0
WIFI"""
t = t[:i] + BODY_NEW + t[j + len(BODY_OLD_END):]

# 1d. the unit and the patch summary describe what actually happens now
t = one(t, 'Description=Y700 A129 ath11k module loader (no PCI bus writes)',
        'Description=Y700 A129 wifi observer (ath11k_pci built in, no PCI bus writes)',
        "unit description")
t = one(t, 'P "WIFI module loader armed insmod=on"',
        'P "WIFI observer armed ath11k_pci=built-in fw=in-initramfs"', "patch summary")
t = one(t, '# the script\'s own budget (240 s insmod + 60 s wait + card pushes) is longer than',
        '# the script scans for up to 40 s and pushes the card mirror several times, so it',
        "unit comment")
t = one(t, '# systemd\'s 90 s default, and a killed oneshot leaves no trace in the log',
        '# needs longer than systemd\'s 90 s default in every case.',
        "unit comment2")

assert "ath11k_pci.ko" not in t.split("cat > \"$R/usr/local/bin/y700-wifi.sh\"")[0].split("# ---- 4b.")[1], "ko leftovers in 4b"
assert "insmod=off" in t and "builtin=yes" in t and "decision drv=" in t
wr(A + "/a129/patch.sh", t)

# ---------------- 2. the init hook ----------------
ini = rd(A + "/a128/init-new").replace("A128", "A129").replace("a128", "a129")
wr(A + "/a129/init-new", ini)
assert "A129 PATCH_RUN" in ini

# ---------------- 3. prep: config + initramfs firmware ----------------
pr = rd(A + "/a128-prep.sh").replace("A128", "A129").replace("a128", "a129")

pr = one(pr, "sed -i 's/^CONFIG_ATH11K_PCI=.*$/CONFIG_ATH11K_PCI=m/' .config",
         r"sed -i 's/^CONFIG_ATH11K_PCI=.*$/CONFIG_ATH11K_PCI=y/' .config", "ath11k_pci sed")
pr = one(pr, "grep -q '^CONFIG_ATH11K_PCI=m$' .config || { echo A129_CFG_PCI_NOT_MODULE; exit 1; }",
         "grep -q '^CONFIG_ATH11K_PCI=y$' .config || { echo A129_CFG_PCI_NOT_BUILTIN; exit 1; }",
         "ath11k_pci gate")

CFG_BLOCK = r"""# ---- A129: pay for the firmware with kernel text ----
# CONFIG_KALLSYMS_ALL only adds the names of data symbols to /proc/kallsyms; the
# text symbols that initcall_debug and every backtrace here depend on stay.  It
# is worth 2752512 bytes of Image, measured on this exact tree.
./scripts/config --file .config -d KALLSYMS_ALL
grep -q '^CONFIG_KALLSYMS=y$' .config || { echo A129_KALLSYMS_LOST; exit 1; }
grep -q '^# CONFIG_KALLSYMS_ALL is not set$' .config || { echo A129_KALLSYMS_ALL_STILL_ON; exit 1; }
# the embedded cpio is XZ-compressed instead of gzip: same content, 926776 bytes
# smaller, and CONFIG_XZ_DEC is already built in for the bootloader ramdisk.
./scripts/config --file .config -d INITRAMFS_COMPRESSION_GZIP -e INITRAMFS_COMPRESSION_XZ
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig >> /tmp/y700/a129-olddef.log 2>&1 || { echo A129_OLDDEFCONFIG_FAIL; tail -20 /tmp/y700/a129-olddef.log; exit 1; }
grep -q '^# CONFIG_KALLSYMS_ALL is not set$' .config || { echo A129_KALLSYMS_ALL_BACK; exit 1; }
grep -q '^CONFIG_INITRAMFS_COMPRESSION_XZ=y$' .config || { echo A129_NOT_XZ; exit 1; }
grep -q '^CONFIG_XZ_DEC=y$' .config || { echo A129_XZ_DEC_MISSING; exit 1; }
grep -q '^CONFIG_KALLSYMS=y$' .config || { echo A129_KALLSYMS_BACK; exit 1; }
grep -E '^CONFIG_(KALLSYMS|KALLSYMS_ALL|INITRAMFS_COMPRESSION_XZ|INITRAMFS_COMPRESSION_GZIP|XZ_DEC)=' .config

# ---- A129: the WCN6855 firmware has to be inside the initramfs ----
# ath11k asks for ath11k/WCN6855/hw2.1/{amss.bin,board-2.bin,m3.bin} from the MHI
# power-up, which happens inside the initcall window.  amss.bin/m3.bin/regdb.bin
# are the asphalt-linux set (oneplus/negroni ships the same WCN6855 hw2.1 parts),
# board-2.bin is the Y700 encoding from the stock qca6490 bdwlang.elf.
IR=/tmp/y700/initramfs
FWA=/tmp/y700/fw-asphalt
mkdir -p "$IR/lib/firmware/ath11k/WCN6855/hw2.1" || exit 1
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/amss.bin"  "$IR/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin"  || exit 1
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/m3.bin"     "$IR/lib/firmware/ath11k/WCN6855/hw2.1/m3.bin"     || exit 1
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/regdb.bin" "$IR/lib/firmware/ath11k/WCN6855/hw2.1/regdb.bin" || exit 1
cp -f "$FWA/lenovo/tb320fc/wifi/board-2.bin"         "$IR/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin" || exit 1
# cfg80211 asks for /lib/firmware/regulatory.db from regulatory_init_db(), which
# runs at up=3.6 s - also inside the initramfs, also always failed with -2.
cp -f "$FWA/oneplus/negroni/WCN6855/hw2.1/regdb.bin" "$IR/lib/firmware/regulatory.db" || exit 1
for f in amss.bin board-2.bin m3.bin regdb.bin; do
	cmp -s "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f" "$FWA/oneplus/negroni/WCN6855/hw2.1/$f" 2>/dev/null && continue
	cmp -s "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f" "$FWA/lenovo/tb320fc/wifi/$f" 2>/dev/null && continue
	echo "A129_FW_COPY_DIFF $f"; exit 1
done
cmp -s "$IR/lib/firmware/regulatory.db" "$FWA/oneplus/negroni/WCN6855/hw2.1/regdb.bin" || { echo A129_REGDB_COPY_DIFF; exit 1; }
for f in amss.bin board-2.bin m3.bin regdb.bin; do
	echo "initramfs fw $f size=$(wc -c < "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f") sha=$(sha256sum "$IR/lib/firmware/ath11k/WCN6855/hw2.1/$f" | cut -c1-16)"
done
echo "initramfs regulatory.db size=$(wc -c < "$IR/lib/firmware/regulatory.db")"
# the module of A127/A128 must be gone: a stale .ko in the initramfs would make
# the round ambiguous about which driver ran.
rm -rf "$IR/y700-ko"
[ -e "$IR/y700-ko/ath11k_pci.ko" ] && { echo A129_KO_STILL_IN_INITRAMFS; exit 1; }
echo "initramfs ath11k dir=[$(ls "$IR/lib/firmware/ath11k/WCN6855/hw2.1" | tr '\n' ',')] total=$([ $(du -sk "$IR" | cut -f1) ])K"
echo ATH129_FW_OK
"""

anchor = "echo A129_PREP_OK"
if pr.count(anchor) != 1:
    raise SystemExit("PREP anchor found %d times" % pr.count(anchor))
pr = pr.replace(anchor, CFG_BLOCK + anchor, 1)
# A128 asserted the *absence* of ath11k firmware in the initramfs.  A129 is the
# round that puts it there, so the old tripwire has to go - build.sh is the one
# that insists on the files now.
pr = one(pr, 'if [ -d /tmp/y700/initramfs/lib/firmware/ath11k ] ; then echo A129_UNEXPECTED_ATH11K_FW; exit 1; fi',
         '# A129: an ath11k directory in the initramfs is the point of the round (baked below)',
         "old fw tripwire")
wr(A + "/a129-prep.sh", pr)
assert "CONFIG_ATH11K_PCI=y" in pr and "ATH129_FW_OK" in pr

# ---------------- 4. build ----------------
b = rd(A + "/a128-build.sh").replace("A128", "A129").replace("a128", "a129")

MB_START = "# ---- A129: ath11k_pci lives in a module; build it, ship it in the initramfs ----"
MB_END = 'echo "initramfs hash after the .ko=$IRHASH"\n'
i, j = b.find(MB_START), b.find(MB_END)
if i < 0 or j < 0:
    raise SystemExit("MODULE BLOCK SLICE NOT FOUND i=%s j=%s" % (i, j))
b = b[:i] + r"""# ---- A129: ath11k_pci is built in, and its firmware rides in the initramfs ----
grep -q '^CONFIG_ATH11K=y$' .config || { echo A129_ATH11K_CORE_NOT_BUILTIN; exit 1; }
grep -q '^CONFIG_ATH11K_PCI=y$' .config || { echo A129_ATH11K_PCI_NOT_BUILTIN; exit 1; }
for c in MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_PWRSEQ PCI_PWRCTRL_GENERIC POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN PCIE_QCOM CFG80211 MAC80211; do
	grep -q "^CONFIG_$c=y$" .config || { echo "A129_PWR_PATH_NOT_BUILTIN $c"; exit 1; }
done
grep -q '^# CONFIG_KALLSYMS_ALL is not set$' .config || { echo A129_KALLSYMS_ALL_STILL_ON; exit 1; }
grep -q '^CONFIG_INITRAMFS_COMPRESSION_XZ=y$' .config || { echo A129_INITRAMFS_NOT_XZ; exit 1; }
echo "A129 config: ath11k_pci built in, KALLSYMS_ALL off, embedded cpio XZ"
for m in lib/firmware/ath11k/WCN6855/hw2.1/amss.bin lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin \
         lib/firmware/ath11k/WCN6855/hw2.1/m3.bin lib/firmware/ath11k/WCN6855/hw2.1/regdb.bin \
         lib/firmware/regulatory.db; do
	[ -s "$IR/$m" ] || { echo "A129_INITRAMFS_FW_MISSING $m"; exit 1; }
	echo "initramfs carries $m ($(stat -c %s "$IR/$m") bytes)"
done
[ -e "$IR/y700-ko/ath11k_pci.ko" ] && { echo A129_KO_STILL_IN_INITRAMFS; exit 1; }
""" + b[j + len(MB_END):]

# the size gate keeps its number, the reference points change
b = one(b, 'echo "Image $sz bytes (a121 was 57458176, a122-a124 were 60211456)"',
        'echo "Image $sz bytes (a128 without fw was 57590272; a122-a124 with fw were 60211456 and died)"',
        "image size echo")
b = one(b, 'if nm vmlinux | grep -q ath11k_pci_probe ; then echo A129_ATH11K_PCI_STILL_BUILTIN; exit 1; fi',
        'nm vmlinux | grep -q ath11k_pci_probe || { echo A129_ATH11K_PCI_NOT_BUILTIN; exit 1; }',
        "probe gate")
b = one(b, 'echo "ath11k_pci glue is out of vmlinux, as intended"',
        'nm vmlinux | grep -q ath11k_pci_init || { echo A129_ATH11K_PCI_INITCALL_MISSING; exit 1; }\necho "ath11k_pci glue is built in, as intended"',
        "initcall gate")
b = one(b, '[ "$LOST" -le 400 ] || { echo A129_STRING_LOSS_TOO_MANY; head -30 /tmp/y700/kbuild/a129-strings-lost.txt; exit 1; }',
        '# KALLSYMS_ALL=n removes the names of data symbols, which are plain text in\n# the Image, so the loss budget has to be much larger than the noise-only 400 of\n# A128.  The named vocabulary checks below are what actually protect the round.\n[ "$LOST" -le 9000 ] || { echo A129_STRING_LOSS_TOO_MANY; head -30 /tmp/y700/kbuild/a129-strings-lost.txt; exit 1; }',
        "strings loss gate")

b = one(b, '[ -s "$IR/y700-ko/ath11k_pci.ko" ] || { echo A129_KO_NOT_IN_TREE; exit 1; }',
        r"""for m in 'ath11k/WCN6855/hw2.1/amss.bin' 'ath11k/WCN6855/hw2.1/board-2.bin' \
         'ath11k/WCN6855/hw2.1/m3.bin' 'firmware/regulatory.db'; do
	grep -q "$m" usr/initramfs_data.cpio || { echo "A129_CPIO_FW_MISSING $m"; exit 1; }
	echo "cpio carries $m"
done
if grep -q 'y700-ko/ath11k_pci.ko' usr/initramfs_data.cpio ; then echo A129_CPIO_STILL_CARRIES_KO; exit 1; fi""",
        "ko-in-tree gate")
b = one(b, 'grep -q \'"$INSMOD" /usr/lib/y700/ath11k_pci.ko\' usr/initramfs_data.cpio || { echo A129_NO_INSMOD_PATH; exit 1; }',
        "grep -q 'builtin=yes' usr/initramfs_data.cpio || { echo A129_NO_BUILTIN_MARK; exit 1; }",
        "insmod path gate")
b = one(b, "grep -q 'timeout 240 ' usr/initramfs_data.cpio || { echo A129_NO_LONGER_USES_TIMEOUT; exit 1; }",
        "grep -q 'RESULT ssids=' usr/initramfs_data.cpio || { echo A129_NO_SCAN_REPORT; exit 1; }\ngrep -q 'ath11k_pci is built in this round' usr/initramfs_data.cpio || { echo A129_NO_LOAD_SKIP_LINE; exit 1; }\necho \"A129 the observer, not a loader, is inside the initramfs\"",
        "loader gate")
b = one(b, 'echo "A129 the module and the loader are inside the initramfs"',
        'echo "A129 the firmware and the built-in driver are inside the image"',
        "loader echo")

# A127's gate insisted the patch reported an installed .ko.  A129 has no module,
# so the same slot now asserts the patch cleans the old one out of the root.
b = one(b, "grep -q 'A129 KO installed' usr/initramfs_data.cpio || { echo A129_NO_KO_REPORT; exit 1; }",
        "grep -q 'removed the stale ath11k_pci.ko' usr/initramfs_data.cpio || { echo A129_NO_KO_CLEANUP; exit 1; }",
        "ko report gate")
# "load start ver=" was the insmod branch of A128.  A129 has no load branch, so
# the slot asserts the success branch instead.
b = one(b, "grep -q 'load start ver=' usr/initramfs_data.cpio || { echo A129_NO_LOAD_TRACE; exit 1; }",
        "grep -q 'RESULT wifi-up iface=' usr/initramfs_data.cpio || { echo A129_NO_WIFI_UP_BRANCH; exit 1; }",
        "load trace gate")
# the A128 decision line keyed on drvdir=; A129 has no drvdir to talk about
b = one(b, "grep -q 'decision drvdir=' usr/initramfs_data.cpio || { echo A129_NO_DECISION_LINE; exit 1; }",
        "grep -q 'decision drv=' usr/initramfs_data.cpio || { echo A129_NO_DECISION_LINE; exit 1; }",
        "decision gate")
wr(A + "/a129-build.sh", b)
for f in (A + "/a129/patch.sh", A + "/a129/init-new", A + "/a129-prep.sh", A + "/a129-build.sh"):
    print("%-28s %d bytes" % (f, os.path.getsize(f)))
print("MK_A129_OK")
