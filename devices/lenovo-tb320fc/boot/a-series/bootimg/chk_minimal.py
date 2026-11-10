#!/usr/bin/env python3
"""Verify the A1m boot set really is what we think it is.

Same brace-depth walk as mk_a1_dtb.py:set_status_disabled, so a child node's
`status` can never be mistaken for the node's own.
"""
import os
import re
import sys

WANT_OFF = ('gpu@3d00000', 'gmu@3d6a000', 'clock-controller@3d90000',
            'pcie@1c00000', 'phy@1c06000', 'phy@88e8000',
            'isp@acb7000', 'cci@ac15000', 'cci@ac16000',
            'clock-controller@aaf0000', 'clock-controller@ade0000',
            'clock-controller@af00000', 'phy@ae94400', 'phy@ae96400',
            'remoteproc@2400000', 'remoteproc@3000000', 'sram@146aa000',
            'mailbox@ed18000', 'rng@10c3000', 'hwlock@1f40000',
            'syscon@1fc0000',
            'power-management@c300000', 'sram@c3f0000',
            'thermal-sensor@c263000', 'thermal-sensor@c265000',
            'pmu@19091000', 'codec@31e0000', 'codec@3200000',
            'codec@3220000', 'codec@3240000',
            # A1r: the PDC killed A1q (drivers/irqchip/qcom-pdc.c binds
            # "qcom,pdc" and pokes 0x0b220000); TLMM is freed from deferring by
            # deleting its wakeup-parent property instead, so this stays off.
            'interrupt-controller@b220000',
            # A1s: A1r died in the probe of this icc provider (aggre2-noc,
            # 0x01700000).  Its phandle 0x2f must be gone from every consumer too.
            'interconnect@1700000')

WANT_ON = ('clock-controller@100000', 'rsc@17a00000', 'pinctrl@3440000',
           'pinctrl@f100000',
           'ufshc@1d84000', 'phy@1d80000', 'interrupt-controller@17100000',
           'msi-controller@17140000', 'system-cache-controller@19200000',
           'mmc@8804000', 'framebuffer@b8000000', 'pmic@0', 'pmic@1',
           'pmic@4',
           # A45: the dwc3 wrapper and its HS phy are on purpose.
           'usb@a600000', 'phy@88e3000')

CS_PREFIX = ('funnel@', 'replicator@', 'tmc@', 'tpda@', 'tpdm@', 'cti@',
             'stm@', 'tpiu@')

# A48: the node sweep proved a third of the pinned-off set harmless, and
# mk_a1_dtb.py enables them again from a1/unpin_next.txt.  This check has to
# follow that file instead of contradicting it, so promoted nodes leave
# WANT_OFF and are asserted enabled (they have no own status at all, which is
# what 'ok' means here).  The same list gates the coresight prefix scan.
def _unpinned():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     'unpin_next.txt')
    if not os.path.exists(p):
        return set()
    return {ln.strip().split('/')[-1] for ln in open(p, encoding='utf-8')
            if ln.strip() and not ln.startswith('#')}


# A51: mk_a1_dtb.py also takes Y700_EXTRA_DISABLE, which re-pins nodes that
# unpin_next.txt has already promoted.  displayport-controller@ae90000 is
# promoted (its probe runs, it just fails with -ENOENT) but its missing
# of_graph endpoint is exactly what stops msm_dpu from ever becoming a DRM
# master, so A51 pins it again.  Read the same env here or this check
# contradicts the DT that is actually built.
EXTRA_DISABLE = {n.strip().split('/')[-1]
                 for n in os.environ.get('Y700_EXTRA_DISABLE', '').split(',')
                 if n.strip()}


UNPINNED = _unpinned() - EXTRA_DISABLE
WANT_OFF = (tuple(n for n in WANT_OFF if n not in UNPINNED) +
            tuple(sorted(EXTRA_DISABLE)))
WANT_ON = WANT_ON + tuple(sorted(UNPINNED))


def own_props(lines, hdr):
    ind = lines[hdr][:len(lines[hdr]) - len(lines[hdr].lstrip())]
    end = lines.index(ind + '};', hdr + 1)
    depth, props = 0, []
    for k in range(hdr + 1, end):
        if depth == 0 and lines[k].strip():
            props.append(lines[k].strip())
        depth += lines[k].count('{') - lines[k].count('}')
    return props


def status_of(lines, name):
    for i, ln in enumerate(lines):
        if ln.strip() == '%s {' % name:
            for p in own_props(lines, i):
                m = re.match(r'status = "([^"]*)";', p)
                if m:
                    return m.group(1)
            return 'ok'
    return None


def main():
    lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
    bad = 0
    for name in WANT_OFF:
        got = status_of(lines, name)
        ok = got == 'disabled'
        bad += 0 if ok else 1
        print('%-4s %-34s %s' % ('OK' if ok else 'BAD', name, got))
    for name in WANT_ON:
        got = status_of(lines, name)
        ok = got not in (None, 'disabled')
        bad += 0 if ok else 1
        print('%-4s %-34s %s' % ('OK' if ok else 'BAD', name, got))

    on = []
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.endswith('{') and not s.startswith('}') and any(
                s[:-1].strip().startswith(p) for p in CS_PREFIX):
            name = s[:-1].strip()
            if status_of(lines, name) != 'disabled' and name not in UNPINNED:
                on.append(name)
    print('coresight still enabled: %d %s' % (len(on), on[:6]))
    bad += len(on)
    text = '\n'.join(lines)
    print('iommus left: %d / iommu-map left: %d'
          % (text.count('iommus = <'), text.count('iommu-map = <')))
    wp = text.count('wakeup-parent')
    print('wakeup-parent left: %d (must be 0)' % wp)
    bad += wp
    ro = text.count('compatible = "ramoops"')
    print('ramoops nodes: %d (must be 1)' % ro)
    bad += 0 if ro == 1 else 1
    if ro == 1:
        print('ramoops addr present: %d' % text.count('ramoops@f0000000 {'))
        bad += 0 if text.count('ramoops@f0000000 {') == 1 else 1
    for node, want in (('y700log@a7000000 {', 1), ('y700logc@f0200000 {', 1),
                       ('memory@9f500000 {', 1)):
        n = text.count(node)
        print('%s nodes: %d (must be %d)' % (node, n, want))
        bad += 0 if n == want else 1
    # y700_ramlog.c pokes the ring through phys_to_virt(), which is only valid if
    # the range really is DRAM as listed by the /memory node.
    banks = []
    for i, ln in enumerate(lines):
        s = ln.strip()
        if (s == 'memory {' or s.startswith('memory@')) and \
                'device_type = "memory";' in own_props(lines, i):
            for p in own_props(lines, i):
                if p.startswith('reg = <'):
                    v = [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', p)]
                    for k in range(0, len(v) - 3, 4):
                        banks.append(((v[k] << 32) | v[k + 1],
                                      (v[k + 2] << 32) | v[k + 3]))
    print('DRAM banks: %s' % [(hex(b), hex(sz)) for b, sz in banks])
    for addr in (0xA7000000, 0xF0200000):
        hit = any(b <= addr and b + sz >= addr + 0x100000 for b, sz in banks)
        print('ring %s inside DRAM: %s (must be True)' % (hex(addr), hit))
        bad += 0 if hit else 1
    icc = len(re.findall(r'interconnects = <[^>]*(?<![0-9a-f])0x2f(?![0-9a-f])',
                         text))
    print('interconnects referencing disabled aggre2 (0x2f): %d (must be 0)' % icc)
    bad += icc
    # A45: the dwc3 wrapper must be a high-speed peripheral with no PDC and no
    # SS phy, or the probe either defers forever or walks into a collapsed block.
    lines2 = text.split('\n')
    hdr = None
    for i, ln in enumerate(lines2):
        if ln.strip() == 'usb@a600000 {':
            hdr = i
            break
    if hdr is None:
        print('usb@a600000 node: MISSING')
        bad += 1
    else:
        own = own_props(lines2, hdr)
        joined = ' '.join(own)
        checks = [
            ('dr_mode peripheral', 'dr_mode = "peripheral";' in joined),
            ('no usb-role-switch', 'usb-role-switch' not in joined),
            ('no role-switch-default-mode', 'role-switch-default-mode' not in joined),
            ('phy-names usb2-phy only', 'phy-names = "usb2-phy";' in joined),
            ('no usb3 phy phandle', '0x42 0x00' not in joined),
            ('maximum-speed high-speed', 'maximum-speed = "high-speed";' in joined),
            ('utmi pipe clk select', 'qcom,select-utmi-as-pipe-clk;' in joined),
            ('no pdc interrupts', '0xbe 0x0e' not in joined and '0xbe 0x0f' not in joined
             and '0xbe 0x11' not in joined),
            ('iommus only via apps_smmu', ('iommus' not in joined)
             or ('iommus = <0x44 ' in joined)),
            ('3 interrupt names only', '"dwc_usb3"' in joined and '"pwr_event"' in joined
            and 'dp_hs_phy_irq' not in joined and 'dm_hs_phy_irq' not in joined
            and 'ss_phy_irq' not in joined),
        ]
        for what, ok in checks:
            print('usb@a600000 %-28s %s' % (what, 'OK' if ok else 'BAD'))
            bad += 0 if ok else 1
    # A46: the eUSB2 HS phy must not be waiting for the I2C eUSB2 repeater,
    # because nothing here drives that bus (CONFIG_I2C_QCOM_GENI is not set) and
    # the wait would park a600000.usb in the deferred queue forever.
    hdr = None
    for i, ln in enumerate(lines2):
        if ln.strip() == 'phy@88e3000 {':
            hdr = i
            break
    joined = ' '.join(own_props(lines2, hdr)) if hdr is not None else ''
    # 0xb8 is the repeater phandle; a bare 0xb8 also shows up as a GIC SPI
    # number, so only phandle-typed phys references count here.
    ref0xb8 = [ln.strip() for ln in lines2
               if re.search(r'phys = <[^>]*(?<![0-9a-f])0xb8(?![0-9a-f])', ln)]
    if ref0xb8:
        print('phy@88e3000 still referenced by: %s' % ref0xb8[:4])
    for what, ok in (('node present', hdr is not None),
                     ('no repeater phys', 'phys = <' not in joined),
                     ('status okay', 'status = "okay";' in joined),
                     ('no 0xb8 phandle user left', not ref0xb8)):
        print('phy@88e3000 %-30s %s' % (what, 'OK' if ok else 'BAD'))
        bad += 0 if ok else 1
    print('CHECK %s' % ('OK' if bad == 0 else 'FAIL %d' % bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
