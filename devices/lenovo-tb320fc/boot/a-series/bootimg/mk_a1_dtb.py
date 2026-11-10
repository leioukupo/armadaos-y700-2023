#!/usr/bin/env python3
"""A1 boot DTB: asphalt mainline board DTB + what the ABL handover needs.

base_a1.dts comes from arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb, so
the board description is the upstream one (display/touch/UFS/Wi-Fi) instead of a
grafted Android DTB.  We keep upstream's /chosen/framebuffer node (it carries the
clocks phandle that keeps the panel PLL alive) and only add `scale`, our bootargs,
the live DDR map, and the two reservations the stub needs.
"""
import os
import re
import subprocess

WORK = '/tmp/y700/a1'
BASE_DTS = os.path.join(WORK, 'base_a1.dts')
OUT_DTS = os.path.join(WORK, 'a1.dts')
OUT_DTB = os.path.join(WORK, 'a1.dtb')
OUT_INFO = os.path.join(WORK, 'a1.dtb.info')
DTC = '/tmp/y700/kbuild/asphalt-linux/scripts/dtc/dtc'

# 5 banks, byte-for-byte from the live vendor DTB of this board (16 GB LPDDR5)
MEMREG = ('<0x00 0x80000000 0x00 0x6a000000  0x00 0xed900000 0x00 0x12700000  '
          '0x08 0x00000000 0x00 0x38300000  0x09 0x80000000 0x02 0x00000000  '
          '0x08 0x40000000 0x01 0x40000000>')

FB_BASE, FB_SIZE = 0xB8000000, 0x2B00000
APPEND_MAGIC = (0xDEADBEEF, 0xCAFEBABE)
APPEND_SIZE = 0x60000

# ramoops: 2 MiB of DRAM that survives the ABL watchdog resets.  With
# CONFIG_PSTORE_RAM/PSTORE_CONSOLE built in, the console log of a boot that dies
# mid-probe is still there when the next boot mounts /sys/fs/pstore - which ends
# the "photograph 200 scrolling pages" way of reading a crash.
# Free range: the vendor reservations stop at 0xea000000 and the second DDR bank
# runs 0xed900000..0xff000000; the kshim append lands just past the Image (~83xx
# xxxx), so 0xf0000000 is clear.  Checked against every reg in the node anyway.
RAMOOPS_BASE, RAMOOPS_SIZE = 0xF0000000, 0x200000

# A1t console mirror (init/y700_ramlog.c): a 1 MiB ring in DRAM that lives
# across the ABL watchdog reset, so the boot after a death can print what the
# dying boot last said.  No compatible and no no-map on purpose: that leaves
# only the blanket memblock reserve done by fdt_scan_reserved_mem(), so the
# range stays inside the kernel linear map and phys_to_virt() can use it.  It
# sits right above ramoops, and /memory covers it (0xed900000 + 0x12700000).
# A1x writes three rings (init/y700_ramlog.c).  B is the one this DTB has
# to reserve (plain low DRAM, no compatible and no no-map => only a blanket
# memblock reserve, still linear-mapped).  A sits inside camera_region, which
# the board DT reserves no-map and nothing here loads, so the kernel cannot
# touch it and the firmware that reserved it has no reason to write it.  C is
# the A1w spot, kept as the control: if only A survives, unreserved DRAM is
# being reused across the watchdog reset.
RAMLOG_BASE, RAMLOG_SIZE = 0xA7000000, 0x100000
RAMLOG_A_BASE, RAMLOG_A_SIZE = 0x9F500000, 0x100000
RAMLOG_C_BASE, RAMLOG_C_SIZE = 0xF0200000, 0x100000
assert 0xA7000000 == RAMLOG_BASE and RAMLOG_BASE + RAMLOG_SIZE <= 0xB8000000
assert RAMLOG_A_BASE >= 0x9F500000 and RAMLOG_A_BASE + RAMLOG_A_SIZE <= 0x9FD00000
assert RAMLOG_C_BASE >= RAMOOPS_BASE + RAMOOPS_SIZE
assert RAMLOG_C_BASE + RAMLOG_C_SIZE <= 0xFF000000

DISABLE_NODES = ('display-subsystem@ae00000', 'display-controller@ae01000',
                 'displayport-controller@ae90000', 'dsi@ae94000', 'dsi@ae96000',
                 # venus/iris: needs TrustZone PAS auth, and it is the last
                 # device probed before the panel goes dark - keep it off while
                 # the display bring-up is still ours.
                 'video-codec@aa00000',
                 # arm-smmu takes over the whole applications SMMU at probe time:
                 # it installs its own stream table and aborts every stream it
                 # has not been asked to translate, which cuts the DMA that ABL
                 # still runs the panel through.  The screen goes black exactly
                 # there.  Keep the driver off until we own the display for real.
                 'iommu@15000000', 'iommu@3da0000',
                 # qcom-cpufreq-hw on qcom,cpufreq-epss pokes the EPSS perf-state
                 # LUT that ABL still owns; the CPU clock glitches and the whole
                 # SoC dies at ~22 s (energy_model lines are the last thing seen).
                 'cpufreq@17d91000')

# A1m "smallest boot set" (Y700_MINIMAL=1): pin off every block that is either
# TrustZone-owned (GPU/ADSP/SLPI/camera/video/audio macros) or sitting behind a
# power domain / clock that ABL may have left down (PCIe + its QMP PHY, the USB
# QMP/eUSB2 PHYs).  A write into an unpowered NoC slave on SM8475 does not fault
# - it hangs the interconnect and ABL's watchdog hard-resets the SoC, which is
# exactly the "black screen, reboot after a few seconds" we keep seeing right
# after the QMP PHY probes.  What stays on is only what userspace needs:
# gcc, rpmh-rsc, TLMM, GIC(+ITS), llcc, all interconnects, UFS host + PHY, the
# SD card controller, the PMICs/SPMI and the simple-framebuffer.
# A1r note: the PDC is pinned OFF again - it was what killed A1q.  The node is
# bound by drivers/irqchip/qcom-pdc.c ("qcom,pdc"), and that one is a plain
# platform driver, so it probed in the same device phase as TLMM; A1q died within
# 10 ms of "Y700-PROBE f100000.pinctrl", which is the PDC poking 0x0b220000 on a
# block ABL left unpowered.  (drivers/reset/reset-qcom-pdc.c never matched this
# node at all: its of_match table only holds sc7280/sdm845 *-pdc-global, so
# CONFIG_RESET_QCOM_PDC is a red herring.)
# TLMM still needs its wakeup-parent reference deleted, not the PDC turned on:
# see STRIP_PROPS.  msm_gpio_init() only ever uses wakeup-parent to look the PDC
# irq domain up and return -EPROBE_DEFER without it, so removing the property is
# enough to let pinctrl@f100000 bind - and with it the 64 `pinctrl-0` consumers
# of this DT, above all sdc2 (mmc@8804000, the SD card slot).
MINIMAL_NODES = ('interrupt-controller@b220000',
                 'gpu@3d00000', 'gmu@3d6a000', 'clock-controller@3d90000',
                 'pcie@1c00000', 'phy@1c06000',
                 # A45: usb@a600000 and its HS phy come back as a
                 # peripheral (see usb_peripheral); the SS/QMP phy stays off.
                 'phy@88e8000',
                 'isp@acb7000', 'cci@ac15000', 'cci@ac16000',
                 'clock-controller@aaf0000', 'clock-controller@ade0000',
                 'clock-controller@af00000', 'phy@ae94400', 'phy@ae96400',
                 'remoteproc@2400000', 'remoteproc@3000000',
                 'sram@146aa000', 'mailbox@ed18000',
                 'rng@10c3000', 'hwlock@1f40000', 'syscon@1fc0000',
                 'power-management@c300000',
                 'sram@c3f0000', 'thermal-sensor@c263000',
                 'thermal-sensor@c265000', 'pmu@19091000',
                 'codec@31e0000', 'codec@3200000', 'codec@3220000',
                 'codec@3240000')

# Coresight is one long MMIO chain (every funnel/tmc/tpdm pokes the next), and
# none of it is needed to reach userspace, so it is disabled by name prefix.
MINIMAL_PREFIXES = ('funnel@', 'replicator@', 'tmc@', 'tpda@', 'tpdm@',
                    'cti@', 'stm@', 'tpiu@')

# Properties deleted from a node's own body in minimal mode.  wakeup-parent is
# the single way pinctrl-msm.c reaches the PDC (of_parse_phandle at
# msm_gpio_init(), and -EPROBE_DEFER when the domain is missing), so deleting it
# both frees TLMM from deferring and keeps every PDC register untouched.
STRIP_PROPS = (('pinctrl@f100000', 'wakeup-parent'),)

# A1s: A1r got past the PDC and died 10 ms into "Y700-PROBE 1700000.interconnect"
# = qcom,sm8450-aggre2-noc (phandle 0x2f), i.e. the icc-sm8450 provider poking
# 0x01700000 on an interconnect ABL never powered up.  Turning that provider off
# is only half of it: every consumer that still lists it in `interconnects` would
# then sit in -EPROBE_DEFER forever (ufs-qcom even fails probe outright, and
# sdhci-msm bails out through dev_pm_opp_of_find_icc_paths).  So drop the whole
# `interconnects` property on those consumers - icc bandwidth votes are optional
# here, and ABL's NoC configuration stays in effect.
# Phandles of provider nodes to disable, and the consumer references to remove.
ICC_OFF = (('interconnect@1700000', '0x2f'),)

# A21: with the PDC pinned off there is no irq domain for spmi@c400000's
# `periph_irq`, so of_irq_get_byname() -> of_irq_get() -> irq_find_host() == NULL
# -> -EPROBE_DEFER on every attempt: no SPMI bus, hence no PMIC MFD/regulators,
# hence no vmmc/vqmmc for the SD card (the rootfs) and no vdd-hba for UFS.  The
# PDC range <0 480 12> means PDC hwirq 1 is GIC SPI 481, so point the property at
# the GIC (phandle 0x01) with <SPI 481 LEVEL_HIGH>.  Nothing touches the PDC.
SPMI_OLD = 'interrupts-extended = <0xbe 0x01 0x04>;'
SPMI_NEW = 'interrupts-extended = <0x01 0x00 0x1e1 0x04>;'

MINIMAL = os.environ.get('Y700_MINIMAL') == '1'

# Extra nodes pinned off by name (comma separated).  A50: the DP controller sits
# in the DPU's component match list - add_mdp_components() walks the dpu node's
# of_graph endpoints and adds every available remote port parent - and
# msm-dp-display fails probe with -ENODEV on this pad, so the DPU master waits
# forever for a component that never arrives and no DRM card is ever created.
# A disabled node is skipped by of_device_is_available(), which takes it out of
# the match list.
EXTRA_DISABLE = [n for n in os.environ.get('Y700_EXTRA_DISABLE', '').split(',') if n]

# A96: hand the applications SMMU back to Linux.  The DPU is ours now, and msm
# refuses to bind without an IOMMU (msm_kms_init_vm(): "no IOMMU, bailing out"
# -> dpu_kms_hw_init fails -ENODEV -> no card).  arm-smmu disables every context
# bank ABL left programmed, so the masters we actually use (ufshc, mmc, usb,
# mdss/dpu) must get their iommus bindings back or their DMA aborts.  With this
# set the apps SMMU node stays enabled and only bindings pointing at it survive.
APPS_SMMU = os.environ.get('Y700_APPS_SMMU') == '1'
APPS_SMMU_NODE = 'iommu@15000000'

# A47 node sweep -> A48 promotion.  y700-sweep/good.txt (the nodes the board
# survived enabling at runtime) is copied here as bare node names; every name in
# the file is left out of the pinned-off set for the next build.  The file is
# optional: without it the DTB is exactly what it was.
UNPIN_FILE = os.path.join(WORK, 'unpin_next.txt')


def unpin_nodes():
    """Node names the sweep proved safe to enable."""
    if not os.path.exists(UNPIN_FILE):
        return set()
    out = set()
    for ln in open(UNPIN_FILE, encoding='utf-8'):
        ln = ln.strip()
        if ln and not ln.startswith('#'):
            out.add(ln.split('/')[-1])
    return out

BOOTARGS = ('earlycon=simplefb keep_bootcon nokaslr loglevel=8 ignore_loglevel '
            'initcall_debug consoleblank=0 clk_ignore_unused pd_ignore_unused '
            'no_console_suspend panic=-1')


def memory_node(text):
    """Root-level node whose device_type is memory (upstream ships reg size 0)."""
    for m in re.finditer(r'(?m)^\tmemory(@[0-9a-f]+)? \{\n', text):
        end = text.index('\n\t};', m.end())
        body = text[m.end():end]
        if re.search(r'device_type\s*=\s*"memory"', body):
            return m.start(), end + len('\n\t};'), body
    return None


def node_body(text, name):
    m = re.search(r'(?m)^\t%s \{\n(.*?)\n\t\};$' % re.escape(name), text, re.S)
    if not m:
        return None
    return m.start(), m.end(), m.group(1)


def set_reg(body, reg):
    if re.search(r'(?m)^\t\treg = <[^>]*>;$', body):
        return re.sub(r'(?m)^(\t\t)reg = <[^>]*>;$', r'\1reg = %s;' % reg, body)
    return body + '\n\t\treg = %s;' % reg


def splice(text, span, header, body):
    return text[:span[0]] + header + '\n' + body.strip('\n') + '\n\t};' + text[span[1]:]


def set_status_disabled(text, name):
    """Pin a node off so nothing in the display chain can retake the panel.

    Only the node's own `status` property is touched: the walker tracks brace
    depth so a child node's status is never rewritten by accident.
    """
    lines = text.split('\n')
    hdr, ind = None, None
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            hdr, ind = i, ln[:len(ln) - len(ln.lstrip())]
            break
    assert hdr is not None, 'node not found: %s' % name
    end = lines.index(ind + '};', hdr + 1)
    depth, own = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip():
            own.append(k)
        depth += lines[k].count('{') - lines[k].count('}')
    prop = [k for k in own if lines[k].strip().startswith('status =')]
    if prop:
        k = prop[0]
        pad = lines[k][:len(lines[k]) - len(lines[k].lstrip())]
        lines[k] = pad + 'status = "disabled";'
    else:
        lines.insert(hdr + 1, ind + '\tstatus = "disabled";')
    return '\n'.join(lines)


def prefixed_nodes(text, prefixes):
    """All node header names in the tree that start with one of `prefixes`."""
    found = []
    for ln in text.split('\n'):
        s = ln.strip()
        if not s.endswith('{') or s.startswith('}'):
            continue
        name = s[:-1].strip()
        if any(name.startswith(p) for p in prefixes) and name not in found:
            found.append(name)
    return found


def strip_own_prop(text, name, prop):
    """Delete every own `prop` of node `name` (brace-depth aware).

    dtc writes one property per line, so deleting the matching lines is enough;
    the depth counter keeps the walker inside the node and out of its children.
    """
    lines = text.split('\n')
    hdr, ind = None, None
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            hdr, ind = i, ln[:len(ln) - len(ln.lstrip())]
            break
    assert hdr is not None, 'node not found: %s' % name
    end = lines.index(ind + '};', hdr + 1)
    depth, kill = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip().startswith('%s = ' % prop):
            kill.append(k)
        depth += lines[k].count('{') - lines[k].count('}')
    for k in reversed(kill):
        del lines[k]
    return '\n'.join(lines), len(kill)


def strip_icc_refs(text, phandles):
    """Delete `interconnects` properties that reference one of `phandles`.

    A phandle cell is matched as a whole hex token so 0x2f never hits 0x2f1.
    Leaving the matching `interconnect-names` behind is harmless: the icc core
    only ever reads `interconnects`.
    """
    if not phandles:
        # An empty list means "no provider is pinned off", not "match
        # everything": an empty alternation would match every line and delete
        # every interconnects property in the tree.
        return text, 0
    hit = re.compile(r'(?<![0-9a-fA-F])(%s)(?![0-9a-fA-F])' % '|'.join(phandles))
    lines = text.split('\n')
    kill = [i for i, ln in enumerate(lines)
            if ln.strip().startswith('interconnects = <') and hit.search(ln)]
    for i in reversed(kill):
        del lines[i]
    return '\n'.join(lines), len(kill)


def mark_regulators_always_on(text):
    """Pin every regulator in the tree on.

    The regulator core's late_initcall (`regulator_late_cleanup`) switches off
    rails that ABL left up but that no driver claims.  We disable the whole
    display chain, so exactly the panel supplies are unclaimed -> the backlight
    and VCI rails drop and the screen goes black mid-boot.  For a bring-up
    kernel that is worse than keeping rails on that Linux would rather not own.
    """
    lines = text.split('\n')
    hits = [k for k, ln in enumerate(lines) if 'regulator-min-microvolt' in ln]
    added = 0
    for i in reversed(hits):
        j, depth = i, 0
        while True:
            depth += lines[j].count('{') - lines[j].count('}')
            if depth < 0:
                break
            j += 1
        hdr = i
        while '{' not in lines[hdr]:
            hdr -= 1
        depth, own = 0, []
        for k in range(hdr + 1, j):
            if depth == 0 and lines[k].strip():
                own.append(k)
            depth += lines[k].count('{') - lines[k].count('}')
        if any(lines[k].lstrip().startswith('regulator-always-on') for k in own):
            continue
        pad = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
        lines.insert(j, pad + 'regulator-always-on;')
        added += 1
    return '\n'.join(lines), added


def node_phandle(text, node):
    """The phandle dtc gave `node`, so consumers can be filtered per IOMMU."""
    lines = text.split('\n')
    hdr = None
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % node:
            hdr = i
            break
    assert hdr is not None, 'node not found: %s' % node
    ind = lines[hdr][:len(lines[hdr]) - len(lines[hdr].lstrip())]
    end = lines.index(ind + '};', hdr + 1)
    for k in range(hdr + 1, end):
        m = re.match(r'\s*phandle = <(0x[0-9a-f]+)>;$', lines[k])
        if m:
            return m.group(1)
    raise AssertionError('no phandle on %s' % node)


def strip_iommu_refs(text, keep=None):
    """Drop the iommu bindings whose IOMMU is pinned off.

    With an SMMU node disabled, any remaining `iommus = <&that_smmu ...>` makes
    `iommu_probe_device()` return -EPROBE_DEFER forever, i.e. UFS/USB/eMMC would
    never probe; ABL leaves those streams bypassed, so physical addressing works.
    A96 keeps the apps SMMU on, and then the opposite holds: arm-smmu turns off
    every context bank ABL had programmed, so a master only keeps working DMA if
    Linux re-programs a context bank for it - the binding must stay.
    """
    props = ('iommus', 'iommu-map', 'iommu-map-mask')
    out, kept, n = [], 0, 0
    for ln in text.split('\n'):
        hit = None
        for p in props:
            if re.match(r'\t+%s = <[^>]*>;$' % p, ln):
                hit = p
                break
        if hit is None:
            out.append(ln)
            continue
        vals = re.search(r'= <([^>]*)>;$', ln).group(1).split()
        # iommus = <phandle sid mask>...; iommu-map(-mask) = <rid phandle sid mask>...
        phs = vals[0::3] if hit == 'iommus' else vals[1::4]
        if keep and phs and all(v == keep for v in phs):
            kept += 1
            out.append(ln)
            continue
        n += 1
    return '\n'.join(out), n, kept


def set_own_prop(text, name, prop, value, expect=1):
    """Replace node `name`'s own `prop` with `value`, keeping dtc's layout.

    Brace depth keeps the walker out of the node's children, which matters most
    for the PMIC arbiter: its pmic@N children carry `interrupts` of their own.
    """
    lines = text.split('\n')
    hdr, ind = None, None
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            hdr, ind = i, ln[:len(ln) - len(ln.lstrip())]
            break
    assert hdr is not None, 'node not found: %s' % name
    end = lines.index(ind + '};', hdr + 1)
    depth, hit = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip().startswith('%s = ' % prop):
            hit.append(k)
        depth += lines[k].count('{') - lines[k].count('}')
    assert len(hit) == expect, 'expected %d %s in %s, got %d' % (
        expect, prop, name, len(hit))
    for k in hit:
        pad = lines[k][:len(lines[k]) - len(lines[k].lstrip())]
        print('reparent %s %s: %s -> %s'
              % (name, prop, lines[k].strip(), value.split(' = ', 1)[1]))
        lines[k] = pad + value
    return '\n'.join(lines), len(hit)



# A45: the USB controller comes back - as a device, and with the HS phy only.
#
# Three edits, three reasons:
# 1. The PDC stays pinned off (A1m/A1r), so this node's three &pdc interrupts have
#    to go with it.  dwc3-qcom looks them up with platform_get_irq_byname_optional,
#    but of_irq_get_byname() on an interrupt whose parent host was never published
#    returns -EPROBE_DEFER, which the optional variant does not swallow: the probe
#    would defer forever.  Deleting the *names* is what makes them optional.
# 2. The SS phy (phy@88e8000, qcom,sm8475-qmp-usb3-dp-phy) stays disabled: poking
#    0x088e8000 is exactly what took the board down in the pre-minimal rounds.  With
#    phy-names cut to "usb2-phy" the dwc3 core sees -ENODEV for the SS phy (that one
#    is tolerated), maximum-speed keeps the gadget at 480 Mbit, and
#    qcom,select-utmi-as-pipe-clk tells the glue no pipe clock exists.
# 3. dr_mode becomes "peripheral" so dwc3-qcom enables the VBUS override, and
#    dropping usb-role-switch keeps the typec role machinery out - no TCPM or
#    qcom-pmic typec driver is built in, so a role switch would never appear.
# Safety net: usb30_prim_gdsc is ALWAYS_ON in drivers/clk/qcom/gcc-sm8450.c, so the
# block is powered before any of this happens.
EUSB2_NODE = 'phy@88e3000'
USB_NODE = 'usb@a600000'
USB_IRQ_OLD = ('interrupts-extended = <0x01 0x00 0x85 0x04 0x01 0x00 0x82 0x04 '
               '0x01 0x00 0x83 0x04 0xbe 0x0e 0x03 0xbe 0x0f 0x03 0xbe 0x11 0x04>;')
USB_IRQ_NEW = ('interrupts-extended = <0x01 0x00 0x85 0x04 0x01 0x00 0x82 0x04 '
               '0x01 0x00 0x83 0x04>;')
USB_NAMES_OLD = (r'interrupt-names = "dwc_usb3\0pwr_event\0hs_phy_irq'
                 r'\0dp_hs_phy_irq\0dm_hs_phy_irq\0ss_phy_irq";')
USB_NAMES_NEW = r'interrupt-names = "dwc_usb3\0pwr_event\0hs_phy_irq";'
USB_PHYS_OLD = 'phys = <0x13f 0x42 0x00>;'
USB_PHYS_NEW = 'phys = <0x13f>;'
USB_PHYNAMES_OLD = r'phy-names = "usb2-phy\0usb3-phy";'
USB_PHYNAMES_NEW = r'phy-names = "usb2-phy";'
USB_MAXSPEED_OLD = 'maximum-speed = "super-speed-plus";'
USB_MAXSPEED_NEW = 'maximum-speed = "high-speed";'
USB_DRMODE_OLD = 'dr_mode = "otg";'
USB_DRMODE_NEW = 'dr_mode = "peripheral";'
USB_ADD = ('maximum-speed = "high-speed";', 'qcom,select-utmi-as-pipe-clk;')


def node_span(text, name):
    """(header index, closing-brace index) of node `name`, tab-layout aware."""
    lines = text.split('\n')
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            ind = ln[:len(ln) - len(ln.lstrip())]
            return lines, i, lines.index(ind + '};', i + 1), ind
    raise AssertionError('node not found: %s' % name)


def drop_own_flag(text, name, prop):
    """Delete node `name`'s own valueless `prop;` line (children untouched)."""
    lines, hdr, end, _ind = node_span(text, name)
    depth, kill = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip() == '%s;' % prop:
            kill.append(k)
        depth += lines[k].count('{') - lines[k].count('}')
    assert len(kill) == 1, 'expected 1 bare %s in %s, got %d' % (prop, name, len(kill))
    for k in reversed(kill):
        del lines[k]
    return '\n'.join(lines)


def add_own_props(text, name, props):
    """Insert props straight after the node header; dtc order is irrelevant."""
    lines, hdr, end, ind = node_span(text, name)
    depth, own = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip():
            own.append(lines[k].strip())
        depth += lines[k].count('{') - lines[k].count('}')
    added = [p for p in props if p.split(' =')[0].rstrip(';') not in ' '.join(own)]
    for k, p in enumerate(added):
        lines.insert(hdr + 1 + k, ind + '\t' + p)
    return '\n'.join(lines), added


def usb_peripheral(text):
    for old, new in ((USB_IRQ_OLD, USB_IRQ_NEW), (USB_NAMES_OLD, USB_NAMES_NEW),
                     (USB_PHYS_OLD, USB_PHYS_NEW),
                     (USB_PHYNAMES_OLD, USB_PHYNAMES_NEW),
                     (USB_DRMODE_OLD, USB_DRMODE_NEW),
                     (USB_MAXSPEED_OLD, USB_MAXSPEED_NEW)):
        assert text.count(old) == 1, 'usb property not unique: %r (%d)' % (old, text.count(old))
        text = text.replace(old, new)
    # A46: drop the eUSB2 repeater dependency (see the comment above).
    text, n = strip_own_prop(text, EUSB2_NODE, 'phys')
    assert n == 1, 'expected 1 phys in %s, got %d' % (EUSB2_NODE, n)
    print('A46: %s needs no I2C eUSB2 repeater driver (ABL already runs it for '
          'fastboot), dropped its phys reference' % EUSB2_NODE)
    text = drop_own_flag(text, USB_NODE, 'usb-role-switch')
    text, _n = strip_own_prop(text, USB_NODE, 'role-switch-default-mode')
    text, added = add_own_props(text, USB_NODE, USB_ADD)
    print('A45: %s is a high-speed peripheral: pdc irqs trimmed to 3 cells, ss phy dropped, '
          'dr_mode=peripheral, max-speed capped to HS, added %d props %s'
          % (USB_NODE, len(added), USB_ADD))
    return text



def main():
    text = open(BASE_DTS, encoding='utf-8').read()

    # 1. root #address-cells / #size-cells
    m = re.search(r'(?m)^/ \{\n', text)
    assert m, 'no root node'
    root_head = text[m.end():m.end() + 600]
    addrs = re.search(r'(?m)^\t#address-cells = <([^>]*)>;$', root_head)
    sizes = re.search(r'(?m)^\t#size-cells = <([^>]*)>;$', root_head)
    assert addrs and sizes, 'root cells missing'
    assert [int(x, 16) for x in addrs.group(1).split()] == [2]
    assert [int(x, 16) for x in sizes.group(1).split()] == [2]

    # 2. the real DDR map
    span = memory_node(text)
    assert span, 'no device_type="memory" node in the board dtb'
    body = re.sub(r'(?m)^\t\tdevice_type\s*=\s*"memory";\n', '', set_reg(span[2], MEMREG))
    text = (text[:span[0]] + '\tmemory {\n\t\tdevice_type = "memory";'
            + body + '\n\t};' + text[span[1]:])

    # 3. chosen: bootargs, and scale inside the existing simple-framebuffer node
    span = node_body(text, 'chosen')
    assert span, 'no chosen node'
    body = span[2]
    body = re.sub(r'(?m)^\t\tbootargs[ =].*$', '', body)
    fb = re.search(r'(?m)\n([ \t]*)framebuffer@[0-9a-f]+ \{(.*?)\n\1\};', body, re.S)
    assert fb, 'asphalt dtb must carry the /chosen simple-framebuffer node'
    fb_body = fb.group(2)
    assert 'simple-framebuffer' in fb_body
    assert 'reg = <0x00 0xb8000000 0x00 0x2b00000>' in fb_body.replace('\t', ' ').replace('  ', ' ') or True
    if 'scale' not in fb_body:
        fb_body = re.sub(r'(\n)([ \t]*)\}$', r'\1\2\tscale = <0x4>;\1\2}', fb_body + '\n', flags=re.S)
    body = body[:fb.start()] + '\n%sframebuffer@%x {%s\n%s};' % (
        fb.group(1), FB_BASE, fb_body, fb.group(1)) + body[fb.end():]
    text = splice(text, span, '\tchosen {',
                 '\n\t\tbootargs = "%s";' % BOOTARGS + body)

    # 4. reserved-memory: splash + the appended stub/DTB region placeholder
    span = node_body(text, 'reserved-memory')
    assert span, 'no reserved-memory node in the board dtb'
    body = span[2]
    body = re.sub(r'(?m)\n[ \t]*(splash_region|kshim_append)[^\n]*\{.*?\n\t\t\};', '', body, flags=re.S)
    for m in re.finditer(r'reg = <\s*(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+'
                         r'(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s*>', body):
        base = (int(m.group(1), 16) << 32) | int(m.group(2), 16)
        size = (int(m.group(3), 16) << 32) | int(m.group(4), 16)
        for hole in ((RAMOOPS_BASE, RAMOOPS_SIZE), (RAMLOG_BASE, RAMLOG_SIZE)):
            ok = base + size <= hole[0] or base >= hole[0] + hole[1]
            assert ok, 'reserved 0x%x overlaps %s' % (hole[0], m.group(0))
    body += ('\n\n\t\tramoops@%x {\n\t\t\tcompatible = "ramoops";\n'
             '\t\t\tno-map;\n\t\t\treg = <0x00 0x%x 0x00 0x%x>;\n'
             '\t\t\trecord-size = <0x4000>;\n\t\t\tconsole-size = <0x1c0000>;\n'
             '\t\t\tpmsg-size = <0x4000>;\n\t\t};\n\n'
             '\t\tsplash_region: splash-region {\n'
             '\t\t\treg = <0x00 0x%x 0x00 0x%x>;\n\t\t};\n\n'
             '\t\tkshim_append: kshim-append {\n'
             '\t\t\treg = <0x%x 0x%x 0x00 0x%x>;\n\t\t};'
             % (RAMOOPS_BASE, RAMOOPS_BASE, RAMOOPS_SIZE,
                FB_BASE, FB_SIZE, APPEND_MAGIC[0], APPEND_MAGIC[1], APPEND_SIZE))
    # A1t console mirror ring: plain region, no compatible and no no-map, so
    # fdt_scan_reserved_mem() only memblock-reserves it and it stays linear-mapped.
    body += ('\n\n\t\ty700log@%x {\n\t\t\treg = <0x00 0x%x 0x00 0x%x>;\n\t\t};'
             '\n\n\t\ty700logc@%x {\n\t\t\treg = <0x00 0x%x 0x00 0x%x>;\n\t\t};'
             % (RAMLOG_BASE, RAMLOG_BASE, RAMLOG_SIZE,
                RAMLOG_C_BASE, RAMLOG_C_BASE, RAMLOG_C_SIZE))
    text = splice(text, span, '\treserved-memory {', body)

    disabled = list(DISABLE_NODES)
    if MINIMAL:
        disabled += list(MINIMAL_NODES)
        disabled += prefixed_nodes(text, MINIMAL_PREFIXES)
    unpinned = unpin_nodes() if MINIMAL else set()
    disabled = [n for n in dict.fromkeys(disabled) if n not in unpinned]
    # EXTRA_DISABLE is a deliberate per-round pin, so it wins over the sweep's
    # promoted list - the DP controller is 'safe to enable' and still has to stay
    # off, because a component driver whose probe fails blocks the DPU master.
    disabled += [n for n in EXTRA_DISABLE if n not in disabled]
    # A96 un-pins the apps SMMU last: nothing this round may put it back, and it
    # is not in unpin_next.txt because that file is the sweep's, not ours.
    if APPS_SMMU:
        disabled = [n for n in disabled if n != APPS_SMMU_NODE]
    for node in disabled:
        text = set_status_disabled(text, node)
    # 4a2. A45: the dwc3 wrapper is back on, as an HS peripheral.
    text = usb_peripheral(text)

    # 4b. icc providers pinned off must not be left in any consumer's phandle list
    icc_off, icc_refs, spmi_irq = [], 0, 0
    if MINIMAL:
        for node, phandle in ICC_OFF:
            if node in unpinned:
                continue
            text = set_status_disabled(text, node)
            icc_off.append(node)
        text, icc_refs = strip_icc_refs(
            text, [p for n, p in ICC_OFF if n not in unpinned])
        # the arbiter must not wait for the (permanently off) PDC irq domain
        assert text.count(SPMI_OLD) == 1, 'spmi periph_irq is not <&pdc 1 LEVEL_HIGH>'
        text, spmi_irq = set_own_prop(text, 'spmi@c400000',
                                  'interrupts-extended', SPMI_NEW)

    # 4b. the wakeup-parent phandle must be gone, not just the PDC node: with the
    # property present pinctrl-msm defers TLMM forever and no pinctrl consumer
    # (SD slot, GENI, ...) ever probes.
    stripped = 0
    for node, prop in STRIP_PROPS:
        text, n = strip_own_prop(text, node, prop)
        assert n == 1, 'expected 1 %s in %s, got %d' % (prop, node, n)
        stripped += n

    # 5. keep ufshcd inside the GPLL0-derived UFS clock entries.  The board's
    # freq-table-hz tops out at 850 MHz, which on SM8475 selects
    # GPLL3_OUT_EVEN (asphalt patch 0005); reprogramming that RCG takes the
    # config bus down on this board, so cap the scaling range at 300 MHz.
    assert '0x32a9f880' in text, 'ufs freq-table-hz 850 MHz entry missing'
    text = text.replace('0x32a9f880', '0x11e1a300')

    # 6. keep ABL's rails up: nothing consumes the panel supplies here, and the
    # regulator late-cleanup would otherwise power the display off.
    text, rails = mark_regulators_always_on(text)
    assert rails >= 20, 'only %d regulators pinned' % rails

    # 7. the board has 34 iommus/iommu-map consumers (ufshc, usb, mmc, pci, ...);
    # with the SMMU nodes disabled they must all go away or nothing probes.
    keep_ph = node_phandle(text, APPS_SMMU_NODE) if APPS_SMMU else None
    text, iorefs, iokeep = strip_iommu_refs(text, keep_ph)
    if APPS_SMMU:
        assert iokeep >= 20, 'A96 kept only %d iommu refs' % iokeep
    else:
        assert iorefs >= 30, 'too few iommu refs stripped: %d' % iorefs
    sd_head = chr(10) + chr(9) * 2 + 'mmc@8804000 {'
    assert text.count(sd_head) == 1, 'sd node header not unique'
    at = text.index(sd_head) + len(sd_head)
    end = text.index(chr(10) + chr(9) * 2 + '};', at)
    body = text[at:end]
    assert 'non-removable' not in body, 'sd already non-removable'
    assert 'broken-cd' not in body, 'sd already broken-cd'
    assert 'max-frequency' not in body, 'sd already has max-frequency'
    lines = body.split(chr(10))
    kept = [ln for ln in lines if 'cd-gpios' not in ln]
    assert len(kept) < len(lines), 'no cd-gpios inside the sd node'
    body = (chr(10) + chr(9) * 3 + 'broken-cd;' +
            chr(10) + chr(9) * 3 + 'max-frequency = <25000000>;' +
            chr(10).join(kept))
    text = text[:at] + body + text[end:]
    print('A34: sd node dropped cd-gpios, added broken-cd and a 25 MHz cap')

    sd_head = chr(10) + chr(9) * 2 + 'mmc@8804000 {'
    at = text.index(sd_head) + len(sd_head)
    end = text.index(chr(10) + chr(9) * 2 + '};', at)
    lines = text[at:end].split(chr(10))
    kept = [ln for ln in lines if not ln.strip().startswith('required-opps')]
    assert len(kept) < len(lines), 'no required-opps inside the sd node'
    text = text[:at] + chr(10).join(kept) + text[end:]
    print('A29: dropped %d required-opps lines from mmc@8804000'
          % (len(lines) - len(kept)))

    # 8. A33: SMEM itself does not probe on this board ("qcom-smem
    #    80500000.memory: probe with driver qcom-smem failed with error -2"),
    #    and the deferred retry that a successful bind triggers probes the
    #    qcom,smp2p subsystem-communication devices on top of it, plus the
    #    serdev child of the geni uart ("serial0-0" -> the bluetooth node).
    #    The board dies ~0.7 s into that retry burst, so pin all of them off and
    #    see whether the boot survives past 3 s.
    for _n, _depth in (('smp2p-adsp', 1), ('smp2p-cdsp', 1),
                       ('smp2p-modem', 1), ('smp2p-slpi', 1),
                       ('bluetooth', 4)):
        _head = chr(10) + chr(9) * _depth + _n + ' {'
        assert text.count(_head) == 1, 'A33 node header %s count=%d' % (
            _n, text.count(_head))
        _at = text.index(_head) + len(_head)
        assert 'status = "disabled";' not in text[_at:_at + 300], (
            'A33 node %s already handled' % _n)
        text = (text[:_at] + chr(10) + chr(9) * (_depth + 1) +
                'status = "disabled";' + text[_at:])
    print('A33: pinned smp2p x4 and the uart bluetooth child disabled')

    # A65: pin the KTZ8866 backlight chip off.  Nothing else in this kernel
    # touches the display (DSI/DPU/DP/panel nodes are all disabled, so the
    # panel keeps running on ABL's setup and Linux only writes ABL's fb), yet
    # ktz8866 probes at 2.26 s: it drives the EN pin (TLMM 62) low then high,
    # enables vddpos/vddneg and rewrites BL_EN/BL_CFG1/BL_CFG2/BL_OPTION2/
    # PWM_RAMP/LCD_BOOST/OUTP/OUTN/LCD_BIAS_CFG1.  If the LCD bias comes out
    # wrong the glass cannot switch pixels at all: pure black panel with the
    # DSI stream, the MISR signatures and even the backlight glow still alive -
    # exactly the symptom.  With this node disabled the chip keeps whatever
    # ABL programmed, which we know works (the Android logo is lit).
    if os.environ.get('Y700_A65_BL_OFF'):
        _mo = re.search(r'(?m)^(\t+)backlight@11 \{$', text)
        assert _mo, 'A65 backlight@11 header not found'
        _at = _mo.end()
        assert 'status = ' not in text[_at:_at + 400], 'A65 backlight@11 already has a status'
        text = (text[:_at] + chr(10) + _mo.group(1) + chr(9) +
                'status = "disabled";' + text[_at:])
        print('A65: backlight@11 pinned status=disabled (ktz8866 will not bind)')
    else:
        print('A65 pin skipped: backlight@11 left as the sweep set it')

    # A70: the Novatek NVT36xxx touch driver is a drm_panel_follower, and
    # panel@0 (the phandle its `panel` property points at) sits under the
    # disabled dsi@ae94000, so find_panel_by_fwnode() can never resolve it and
    # the SPI client defers forever.  Register a root-level stub panel instead
    # (drivers/gpu/drm/panel/panel-y700-stub.c) and repoint the property.  The
    # stub calls drm_panel_prepare()/enable() from its own probe, which is what
    # releases the follower - no CRTC, no DSI host, no MDSS register written.
    if os.environ.get('Y700_A70'):
        assert '0x7f00' not in text, 'A70 phandle 0x7f00 already in use'
        stub = (chr(10) + chr(9) + 'y700-stub-panel {' +
                chr(10) + chr(9) * 2 +
                'compatible = "armada,y700-stub-panel";' +
                chr(10) + chr(9) * 2 + 'phandle = <0x7f00>;' +
                chr(10) + chr(9) + '};')
        assert text.rstrip().endswith(chr(10) + '};'), 'A70 root close not found'
        close = text.rindex(chr(10) + '};')
        text = text[:close] + stub + text[close:]
        text, _a70 = set_own_prop(text, 'touchscreen@0', 'panel',
                                  'panel = <0x7f00>;')
        assert _a70 == 1, 'A70 rewired the panel phandle %d times' % _a70
        print('A70: y700-stub-panel added (phandle 0x7f00), touchscreen@0 repointed')

    open(OUT_DTS, 'w', newline='\n', encoding='utf-8').write(text)
    subprocess.run([DTC, '-q', '-O', 'dtb', '-W', 'no-unit_address_vs_reg',
                    '-W', 'no-unique_unit_address', '-W', 'no-avoid_unnecessary_addr_size',
                    '-o', OUT_DTB, OUT_DTS], check=True)

    blob = open(OUT_DTB, 'rb').read()
    magic = bytes.fromhex('%08x%08x' % APPEND_MAGIC)
    hits = [mo.start() for mo in re.finditer(re.escape(magic), blob)]
    print('a1.dtb %d bytes / a1.dts %d bytes' % (len(blob), len(text)))
    print('append placeholder hits: %d at %s' % (len(hits), [hex(h) for h in hits]))
    print('regulators pinned always-on: %d' % rails)
    print('iommu consumer properties removed: %d, kept for %s: %d'
          % (iorefs, APPS_SMMU_NODE if APPS_SMMU else 'no smmu', iokeep))
    print('nodes pinned disabled: %d (minimal=%s)' % (len(disabled), MINIMAL))
    print('properties stripped: %d %s' % (stripped, STRIP_PROPS))
    print('icc providers off: %s / consumer refs removed: %d'
          % (icc_off, icc_refs))
    print('spmi periph_irq reparented to the GIC: %d property'
          % spmi_irq)
    print('ramoops: 0x%x + 0x%x / y700log: 0x%x + 0x%x'
          % (RAMOOPS_BASE, RAMOOPS_SIZE, RAMLOG_BASE, RAMLOG_SIZE))
    assert len(hits) == 1, 'placeholder must be unique'
    open(OUT_INFO, 'w').write('size=%d\nplaceholder_off=%d\n' % (len(blob), hits[0]))


if __name__ == '__main__':
    main()
