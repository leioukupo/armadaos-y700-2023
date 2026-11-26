#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Post-restore prep for the TB320FC (Y700 Gen 2):
#   1) re-slice LUN0: userdata shrinks, linuxroot takes the rest;
#   2) pin LUN4 slot attributes for the chosen boot slot across every _a/_b pair.
#
# Never use firehose setactiveslot on this board: it writes dont-boot-again on the wrong
# side of the pair (PROGRESS A187/A204), so the pin here is done by editing the backup
# GPT fields (bit48-51 priority, bit52-55 retry, bit55 dont-boot-again; A204 measured it).
#
#   gpt-slice-pin.py --dir WORK [--ref-gpt F] [--userdata-end N] [--lr-start N]
#                    [--lr-end N] [--pin a|b] [--prim4 F] [--back4 F]
#
# Reads WORK/gptbak/prim0.bin and WORK/gptbak/back0.bin (live dumps) and writes
# WORK/new_prim0.bin / new_back0.bin; the same for LUN4 when the prim4/back4 dumps exist.
#
# --ref-gpt is a GPT dump that still contains a linuxroot entry, so the new entry keeps
# the original type/unique GUIDs. Without one, an entry is synthesised from the values
# this board actually used (type 0fc63daf-8483-477e-89c4-89b87c83a0b6 = generic basic
# data, unique 79a8dffb-b80a-507b-84b2-c101dc650123). The boot chain addresses this
# partition by PARTLABEL/ filesystem UUID, so the unique GUID is not load-bearing.
import argparse
import binascii
import struct
import uuid

SEC = 4096
DEFAULT_TYPE_GUID = '0fc63daf-8483-477e-89c4-89b87c83a0b6'
DEFAULT_UNIQ_GUID = '79a8dffb-b80a-507b-84b2-c101dc650123'


def load(path):
    buf = bytearray(open(path, 'rb').read())
    off = buf.find(b'EFI PART')
    if off < 0:
        raise SystemExit('%s: no EFI PART' % path)
    my, alt, fu, lu = struct.unpack_from('<4Q', buf, off + 24)
    entba, cnt, esz, _tc = struct.unpack_from('<QIII', buf, off + 72)
    return buf, off, dict(entba=entba, cnt=cnt, esz=esz, lu=lu, first=my - off // SEC)


def recrc(buf, off, cnt, esz, entba, first):
    base = (entba - first) * SEC
    crc = binascii.crc32(bytes(buf[base:base + cnt * esz])) & 0xffffffff
    struct.pack_into('<I', buf, off + 88, crc)
    struct.pack_into('<I', buf, off + 16, 0)
    struct.pack_into('<I', buf, off + 16, binascii.crc32(bytes(buf[off:off + 92])) & 0xffffffff)
    return crc


def ref_lroot(path):
    want = 'linuxroot'.encode('utf-16-le')
    d = open(path, 'rb').read()
    for off in range(0, len(d) - 128, 128):
        e = d[off:off + 128]
        if e[:16] != b'\0' * 16 and e[56:56 + len(want)] == want:
            return bytearray(e)
    raise SystemExit('%s: no linuxroot entry in the reference table' % path)


def synthesised_lroot():
    e = bytearray(128)
    e[0:16] = uuid.UUID(DEFAULT_TYPE_GUID).bytes_le
    e[16:32] = uuid.UUID(DEFAULT_UNIQ_GUID).bytes_le
    e[56:56 + 76] = 'linuxroot'.encode('utf-16-le').ljust(72, b'\0')[:72]
    return e


def reslice(work, ref, ud_end, lr_start, lr_end):
    for src, out in (('gptbak/prim0.bin', 'new_prim0.bin'), ('gptbak/back0.bin', 'new_back0.bin')):
        buf, off, H = load('%s/%s' % (work, src))
        base = (H['entba'] - H['first']) * SEC
        e = ref_lroot(ref) if ref else synthesised_lroot()
        struct.pack_into('<QQ', e, 32, lr_start, lr_end)
        placed = None
        for k in range(H['cnt']):
            s = base + k * H['esz']
            name = buf[s + 56:s + 128].decode('utf-16-le', 'ignore').rstrip('\0')
            if buf[s:s + 16] == b'\0' * 16:
                if placed is None:
                    buf[s:s + H['esz']] = e
                    placed = k
            elif name == 'userdata':
                struct.pack_into('<Q', buf, s + 40, ud_end)
        if placed is None:
            raise SystemExit('no free entry slot in %s' % src)
        crc = recrc(buf, off, H['cnt'], H['esz'], H['entba'], H['first'])
        open('%s/%s' % (work, out), 'wb').write(bytes(buf))
        print('LUN0 %s: linuxroot->entry#%d %d..%d, userdata end=%d, entriesCRC=%08x -> %s'
              % ('primary' if 'prim' in src else 'backup', placed, lr_start, lr_end, ud_end, crc, out))


def pin(work, target, prim4, back4):
    act, peer = (0x7f, 0xfb) if target == 'a' else (0xfb, 0x7f)
    boot = {0: 0x3f, 1: 0x3a} if target == 'a' else {0: 0x3a, 1: 0x3f}
    for path, out in ((prim4, 'new_prim4.bin'), (back4, 'new_back4.bin')):
        buf, off, H = load(path)
        base = (H['entba'] - H['first']) * SEC
        n = 0
        for k in range(H['cnt']):
            s = base + k * H['esz']
            if buf[s:s + 16] == b'\0' * 16:
                continue
            name = buf[s + 56:s + 128].decode('utf-16-le', 'ignore').rstrip('\0')
            if name.endswith('_a'):
                buf[s + 54] = act if name != 'boot_a' else boot[0]
                n += 1
            elif name.endswith('_b'):
                buf[s + 54] = peer if name != 'boot_b' else boot[1]
                n += 1
        crc = recrc(buf, off, H['cnt'], H['esz'], H['entba'], H['first'])
        open('%s/%s' % (work, out), 'wb').write(bytes(buf))
        print('LUN4 pin->%s: touched=%d entriesCRC=%08x -> %s' % (target, n, crc, out))


ap = argparse.ArgumentParser()
ap.add_argument('--dir', required=True, help='work dir with gptbak/ dumps; outputs land here')
ap.add_argument('--ref-gpt', default=None, help='a GPT dump that still has a linuxroot entry')
ap.add_argument('--userdata-end', type=int, default=36827047)
ap.add_argument('--lr-start', type=int, default=36827048)
ap.add_argument('--lr-end', type=int, default=121268218)
ap.add_argument('--pin', choices=['a', 'b'], default=None)
a = ap.parse_args()

reslice(a.dir, a.ref_gpt, a.userdata_end, a.lr_start, a.lr_end)
if a.pin:
    p4 = '%s/gptbak/prim4.bin' % a.dir
    b4 = '%s/gptbak/back4.bin' % a.dir
    if not (open(p4, 'rb').read() and open(b4, 'rb').read()):
        raise SystemExit('no LUN4 dumps under %s/gptbak' % a.dir)
    pin(a.dir, a.pin, p4, b4)