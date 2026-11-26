#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Rebuild the LUN0 GPT of a TB320FC (Y700 Gen 2) into the stock shape: drop the
# linuxroot entry and let userdata run to the last usable LBA of THIS device.
#
# Why the table has to be rebuilt from the live dump instead of taken from the rom:
# the rom's rawprogram/patch xml carries its own geometry, and the device's UFS backup
# LBA is a property of the chip, not of the package. Writing a foreign backup LBA makes
# the table look corrupt to XBL. So: dump the live primary+backup (edl-restore.sh step 1),
# edit them here, write them back at the dumped offsets.
#
#   gpt-stock.py --prim0 F --back0 F --backup-lba N --out-prim F --out-back F
#
# --backup-lba is the backup GPT's own LBA (read from the primary header); the backup
# copy is read starting four sectors before it, because the dump begins at its header.
import argparse
import binascii
import struct
import sys

SEC = 4096


def fields(buf):
    off = buf.find(b'EFI PART')
    if off < 0:
        raise SystemExit('no EFI PART signature in this dump')
    my, alt, fu, lu = struct.unpack_from('<4Q', buf, off + 24)
    entba, cnt, esz, _tcrc = struct.unpack_from('<QIII', buf, off + 72)
    return off, dict(my=my, alt=alt, fu=fu, lu=lu, entba=entba, cnt=cnt, esz=esz)


def fix(buf, first, tag):
    off, H = fields(buf)
    base = (H['entba'] - first) * SEC
    arr = buf[base:base + H['cnt'] * H['esz']]
    if len(arr) != H['cnt'] * H['esz']:
        raise SystemExit('%s: entry array does not fit the dump' % tag)
    for k in range(H['cnt']):
        e = arr[k * H['esz']:(k + 1) * H['esz']]
        if e[:16] == b'\0' * 16:
            continue
        name = e[56:128].decode('utf-16-le', 'ignore').rstrip('\0')
        if name == 'linuxroot':
            st, en = struct.unpack_from('<QQ', arr, k * H['esz'] + 32)
            print('   %s drop linuxroot %d..%d' % (tag, st, en))
            arr[k * H['esz']:(k + 1) * H['esz']] = b'\0' * H['esz']
        elif name == 'userdata':
            st = struct.unpack_from('<Q', arr, k * H['esz'] + 32)[0]
            print('   %s userdata %d -> %d (%.1f GiB)'
                  % (tag, st, H['lu'], (H['lu'] - st + 1) * SEC / 2 ** 30))
            struct.pack_into('<Q', arr, k * H['esz'] + 40, H['lu'])
    buf[base:base + H['cnt'] * H['esz']] = arr
    crc = binascii.crc32(bytes(arr)) & 0xffffffff
    struct.pack_into('<I', buf, off + 88, crc)
    struct.pack_into('<I', buf, off + 16, 0)
    struct.pack_into('<I', buf, off + 16, binascii.crc32(bytes(buf[off:off + 92])) & 0xffffffff)
    print('  %s hdr@abs=%d ent_lba=%d last_usable=%d entriesCRC=%08x'
          % (tag, off // SEC + first, H['entba'], H['lu'], crc))


ap = argparse.ArgumentParser()
ap.add_argument('--prim0', required=True)
ap.add_argument('--back0', required=True)
ap.add_argument('--backup-lba', required=True, type=int)
ap.add_argument('--out-prim', required=True)
ap.add_argument('--out-back', required=True)
a = ap.parse_args()

prim = bytearray(open(a.prim0, 'rb').read())
back = bytearray(open(a.back0, 'rb').read())
fix(prim, 0, 'primary')
fix(back, a.backup_lba - 4, 'backup')
open(a.out_prim, 'wb').write(bytes(prim))
open(a.out_back, 'wb').write(bytes(back))
print('wrote %s (%d B) %s (%d B)' % (a.out_prim, len(prim), a.out_back, len(back)))