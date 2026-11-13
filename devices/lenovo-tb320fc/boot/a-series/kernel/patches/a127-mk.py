#!/usr/bin/env python3
# Generate the A127 round from the A126 round: the same patch and the same build
# gates, with ath11k_pci turned into a module that the patch installs and the
# wifi unit insmods.  A generator, because the 64 KiB patch must not be retyped.
import os

A = '/tmp/y700'
B = A + '/a1'


def rd(p):
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        return f.read()


def wr(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def one(t, old, new, what):
    n = t.count(old)
    if n != 1:
        raise SystemExit('ANCHOR %s appears %d times' % (what, n))
    return t.replace(old, new, 1)


# ---------------- 1. the initramfs patch ----------------
t = rd(A + '/a126/patch.sh').replace('A126', 'A127').replace('a126', 'a127')

KO_INSTALL = """# ---- 4b. A127: ath11k_pci is a module now, so the .ko rides in the initramfs ----
# A126 proved the endpoint enumerates and the driver exists, but a built-in probe
# runs while the only /lib/firmware in reach is the initramfs one, so MHI gets
# -ENOENT for amss.bin and ath11k_pci_probe returns -110 for good.  The .ko is
# copied into the root here; y700-wifi.sh loads it once the root is mounted.
KO=""
for c in /y700-ko/ath11k_pci.ko /lib/y700/ath11k_pci.ko ; do
\t[ -s "$c" ] && { KO=$c; break; }
done
if [ -n "$KO" ] ; then
\tmkdir -p "$R/usr/lib/y700" 2>/dev/null
\tcp -f "$KO" "$R/usr/lib/y700/ath11k_pci.ko" 2>/dev/null
\tchmod 0644 "$R/usr/lib/y700/ath11k_pci.ko" 2>/dev/null
\tmkdir -p "$R/var/lib/y700" 2>/dev/null
\tS=$(stat -c %s "$R/usr/lib/y700/ath11k_pci.ko" 2>/dev/null)
\tH=$(sha256sum "$R/usr/lib/y700/ath11k_pci.ko" 2>/dev/null | cut -c1-16)
\techo "src=$KO size=$S sha=$H" > "$R/var/lib/y700/ath11k-ko.done" 2>/dev/null
\tU "A127 KO installed src=$KO size=$S sha=$H"
else
\tU "A127 KO MISSING"
fi

# the card in the same boot.  rebind=on in /etc/y700-wifi.conf restores the"""
t = one(t, '# the card in the same boot.  rebind=on in /etc/y700-wifi.conf restores the',
        KO_INSTALL, 'ko install anchor')

t = one(t, 'rebind=off\nif [ -f "$CONF" ] ; then',
        'rebind=off\ninsmod=on\nif [ -f "$CONF" ] ; then', 'conf defaults')

t = one(t, 'L "start fw=[$(ls /usr/lib/firmware/ath11k/WCN6855/hw2.1 2>/dev/null | tr \x27\\n\x27 \x27,\x27)]"',
        'L "start fw=[$(ls /usr/lib/firmware/ath11k/WCN6855/hw2.1 2>/dev/null | tr \x27\\n\x27 \x27,\x27)]"\n'
        'L "start uname=$(uname -r) ko=[$(ls -l /usr/lib/y700/ath11k_pci.ko 2>/dev/null)] lsmod=[$(lsmod 2>/dev/null | tr \x27\\n\x27 \x27,\x27)]"',
        'start evidence line')

# replace the whole rebind experiment with the module load
lines = t.split('\n')
start = end = None
for i, l in enumerate(lines):
    if l.startswith('if [ -n "$DEV" ] && [ "$BOUND" = no ] && [ "$rebind" = on ] ; then'):
        start = i
    if start is not None and l.startswith('if wlan >/dev/null ; then'):
        end = i
        break
if start is None or end is None or end <= start:
    raise SystemExit('REBIND BLOCK NOT FOUND start=%s end=%s' % (start, end))
LOAD = """if [ -n "$DEV" ] && [ "$BOUND" = no ] ; then
\tif [ -d "$DRV" ] ; then
\t\tL "load skip: ath11k_pci already registered (built-in kernel)"
\telif [ ! -e /usr/lib/y700/ath11k_pci.ko ] ; then
\t\tL "load skip: /usr/lib/y700/ath11k_pci.ko not installed"
\telif [ "$insmod" != on ] ; then
\t\tL "load skip: insmod=$insmod in $CONF"
\telse
\t\t# Loading the module is the only supported way in late: a bare bind runs
\t\t# ath11k_pci_sw_reset(), which writes PCIE_SOC_GLOBAL_RESET and rebooted
\t\t# the tablet in A121.  Nothing in this round touches the PCI bus by hand.
\t\tL "load start ver=$(uname -r) ko=/usr/lib/y700/ath11k_pci.ko"
\t\ttimeout 90 insmod /usr/lib/y700/ath11k_pci.ko 2>>"$LOG"; RC=$?
\t\tL "load insmod rc=$RC"
\t\ti=0
\t\twhile [ "$i" -lt 30 ] ; do
\t\t\t[ -e "$DRV/$DEV" ] && break
\t\t\tsleep 2; i=$((i + 1))
\t\tdone
\t\tL "load end bound=$([ -e "$DRV/$DEV" ] && echo yes || echo no) waited=$((i * 2)) net=[$(netlist)]"
\t\tpush
\tfi
fi
"""
lines[start:end] = LOAD.split('\n')
t = '\n'.join(lines)
t = one(t, """# read by /usr/local/bin/y700-wifi.sh
# rebind=on re-probes the ath11k endpoint.  It is OFF because that path writes
# PCIE_SOC_GLOBAL_RESET (a hard reset of the Wi-Fi SoC) and rebooted the tablet
# in A121.  Only turn it on while watching the serial-equivalent console.
rebind=off""",
        """# read by /usr/local/bin/y700-wifi.sh
# insmod=on loads /usr/lib/y700/ath11k_pci.ko once the root is mounted.  That is
# the first moment /usr/lib/firmware/ath11k is reachable, which A126 proved a
# built-in probe never gets.
# rebind is a dead end and is no longer implemented: a bare bind runs
# ath11k_pci_sw_reset(), which writes PCIE_SOC_GLOBAL_RESET and rebooted the
# tablet in A121.
insmod=on
rebind=off""", 'wifi conf body')

t = one(t, 'Description=Y700 A127 ath11k observer (no bus writes)',
        'Description=Y700 A127 ath11k module loader (no PCI bus writes)', 'unit description')
t = one(t, 'P "WIFI observer armed rebind=off"', 'P "WIFI module loader armed insmod=on"', 'patch report')
wr(A + '/a127/patch.sh', t)

# ---------------- 2. the init hook ----------------
wr(A + '/a127/init-new', rd(A + '/a126/init-new').replace('A126', 'A127').replace('a126', 'a127'))

# ---------------- 3. the build script ----------------
b = rd(A + '/a126-build.sh').replace('A126', 'A127').replace('a126', 'a127')
b = b.replace("-j6 Image", "-j${JOBS:-24} Image")

MODBLOCK = """# ---- A127: ath11k_pci lives in a module; build it, ship it in the initramfs ----
# A plain `make Image` never runs modpost, so Module.symvers does not exist and an
# `M=` build dies with "No rule to make target ath11k_pci.ko" (modules.order is
# only generated from the root modules.order).  The standard `make modules` is the
# honest way in: 712 =m modules, incremental, and it produces both Module.symvers
# and ath11k_pci.ko - which is also the proof that modpost resolved every symbol
# the module needs out of the built-in ath11k core.
grep -q \x27^CONFIG_ATH11K=y$\x27 .config || { echo A127_ATH11K_CORE_NOT_BUILTIN; exit 1; }
grep -q \x27^CONFIG_ATH11K_PCI=m$\x27 .config || { echo A127_ATH11K_PCI_NOT_MODULE; exit 1; }
for c in MHI_BUS QRTR QRTR_MHI PCI_PWRCTRL PCI_PWRCTRL_PWRSEQ PCI_PWRCTRL_GENERIC POWER_SEQUENCING POWER_SEQUENCING_QCOM_WCN; do
\tgrep -q "^CONFIG_$c=y$" .config || { echo "A127_PWR_PATH_NOT_BUILTIN $c"; exit 1; }
done
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j${JOBS:-24} modules > /tmp/y700/kbuild/a127-modules.log 2>&1 || { echo A127_MODULES_FAIL; tail -40 /tmp/y700/kbuild/a127-modules.log; exit 1; }
[ -s Module.symvers ] || { echo A127_NO_MODULE_SYMS; exit 1; }
echo "Module.symvers lines=$(wc -l < Module.symvers) undefined_warnings=$(grep -c \x27WARNING: modpost.*undefined\x27 /tmp/y700/kbuild/a127-modules.log)"
KOsrc=drivers/net/wireless/ath/ath11k/ath11k_pci.ko
[ -s "$KOsrc" ] || { echo A127_KO_MISSING; tail -20 /tmp/y700/kbuild/a127-modules.log; exit 1; }
KREL=$(cat include/config/kernel.release)
VERM=$(modinfo -F vermagic "$KOsrc" 2>/dev/null)
DEPS=$(modinfo -F depends "$KOsrc" 2>/dev/null)
echo "ko $(stat -c %s "$KOsrc") bytes kernel=$KREL vermagic=[$VERM] depends=[$DEPS]"
case "$VERM" in "$KREL"*) : ;; *) echo "A127_KO_VERMAGIC_MISMATCH [$VERM] vs $KREL"; exit 1;; esac
nm -u "$KOsrc" | awk \x27{print $NF}\x27 | sort -u > "$B/ko-undef.txt"
nm vmlinux | awk \x27{print $NF}\x27 | sort -u > "$B/vml-all.txt"
UNDEF=$(comm -23 "$B/ko-undef.txt" "$B/vml-all.txt" | tr \x27\\n\x27 \x27 \x27)
echo "ko undefined=$(wc -l < "$B/ko-undef.txt") absent_from_vmlinux=[$UNDEF]"
[ -z "$UNDEF" ] || { echo A127_KO_UNDEFINED_IN_VMLINUX; exit 1; }
mkdir -p "$IR/y700-ko" || exit 1
cp -f "$KOsrc" "$IR/y700-ko/ath11k_pci.ko" || exit 1
sha256sum "$IR/y700-ko/ath11k_pci.ko" "$KOsrc"
grep -q \x27y700-ko/ath11k_pci.ko\x27 "$IR/y700-patch.sh" || { echo A127_PATCH_DOES_NOT_INSTALL_KO; exit 1; }
# the initramfs gained a file, so the embedded cpio is linked into Image again
rm -f usr/initramfs_data.cpio usr/initramfs_data.o
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j${JOBS:-24} Image >> /tmp/y700/kbuild/a127-make2.log 2>&1 || { echo A127_MAKE2_FAIL; tail -40 /tmp/y700/kbuild/a127-make2.log; exit 1; }
tail -6 /tmp/y700/kbuild/a127-make2.log
IRHASH=$(find "$IR" -type f -printf \x27%p %s\\n\x27 | sort | sha256sum | awk \x27{print $1}\x27)
echo "$IRHASH" > "$B/a127-irhash.txt"
cp -f arch/arm64/boot/Image "$B/a127-kernel.img" || exit 1
echo "initramfs hash after the .ko=$IRHASH"
"""
b = one(b, 'tail -8 /tmp/y700/kbuild/a127-make.log',
        'tail -8 /tmp/y700/kbuild/a127-make.log\n' + MODBLOCK, 'make log anchor')

# ath11k_pci_probe is no longer in vmlinux - the gate has to assert the opposite
b = one(b,
        'for s in ath11k_pci_probe qcom_pcie_probe pci_pwrctrl_power_on_devices; do nm vmlinux | grep -q "$s" || { echo "A127_SYMBOL_LOST $s"; exit 1; }; done',
        'for s in ath11k_core_qmi_firmware_ready ath11k_hal_srng_init qcom_pcie_probe pci_pwrctrl_power_on_devices pci_pwrctrl_create_devices; do nm vmlinux | grep -q "$s" || { echo "A127_SYMBOL_LOST $s"; exit 1; }; done\n'
        'n=$(nm vmlinux | grep -c \x27 ath11k_\x27); echo "ath11k core symbols in vmlinux=$n (a126 had 811, 56 of them ath11k_pci)"\n'
        '[ "$n" -ge 700 ] || { echo A127_ATH11K_CORE_LOST $n; exit 1; }\n'
        'if nm vmlinux | grep -q ath11k_pci_probe ; then echo A127_ATH11K_PCI_STILL_BUILTIN; exit 1; fi\n'
        'echo "ath11k_pci glue is out of vmlinux, as intended"', 'symbol gate')

# gate the new payload
b = one(b, 'echo "A127 the touch watchdog is inside the initramfs"',
        '[ -s "$IR/y700-ko/ath11k_pci.ko" ] || { echo A127_KO_NOT_IN_TREE; exit 1; }\n'
        'grep -q \x27ath11k-ko.done\x27 usr/initramfs_data.cpio || { echo A127_NO_KO_MARKER; exit 1; }\n'
        'grep -q \x27insmod /usr/lib/y700/ath11k_pci.ko\x27 usr/initramfs_data.cpio || { echo A127_NO_INSMOD_PATH; exit 1; }\n'
        'grep -q \x27A127 KO installed\x27 usr/initramfs_data.cpio || { echo A127_NO_KO_REPORT; exit 1; }\n'
        'grep -q \x27load start ver=\x27 usr/initramfs_data.cpio || { echo A127_NO_LOAD_TRACE; exit 1; }\n'
        'if grep -q \x27> "$DRV/bind"\x27 usr/initramfs_data.cpio ; then echo A127_DEAD_BIND_PATH_STILL_THERE; exit 1; fi\n'
        'if grep -q \x27> "$DRV/unbind"\x27 usr/initramfs_data.cpio ; then echo A127_DEAD_UNBIND_PATH_STILL_THERE; exit 1; fi\n'
        'echo "A127 the module and the loader are inside the initramfs"\n'
        'echo "A127 the touch watchdog is inside the initramfs"', 'ko gates')

wr(A + '/a127-build.sh', b)

print('a127 patch.sh %d bytes' % len(t))
print('a127 init-new %d bytes' % len(rd(A + '/a127/init-new')))
print('a127 build.sh %d bytes' % len(b))
print('MK_A127_OK')