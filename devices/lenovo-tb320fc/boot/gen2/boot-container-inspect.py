#!/usr/bin/env python3
"""Offline X-ray for a Gen 2 (TB320FC) boot container.

Every blob that XBL has to flat-copy is a 96 MiB `ANDROID!` v4 container whose
payload is an uncompressed arm64 Image (MZ/PE) with a handover stub and a DTB
appended past image_size. This prints the fields that decide whether XBL jumps
to a stub or to garbage, so two blobs can be compared without the device:

  boot-container-inspect.py boot-b-a147.img boot-a-g3.img
"""
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import os

B = os.path.dirname(os.path.abspath(__file__))
AVBTOOL = '/root/y700-artifacts/avbtool.py'


def al4k(n):
    return (n + 4095) // 4096 * 4096


def read32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def dec_branch(word, pc):
    imm = word & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return pc + imm * 4


def is_branch(word):
    return word >> 26 in (0b000101, 0b100101)


def dtb_candidates(blob):
    out, off = [], 0
    while True:
        i = blob.find(b'\xd0\x0d\xfe\xed', off)
        if i < 0:
            return out
        total = struct.unpack_from('>I', blob, i + 4)[0]
        if 1000 < total < 400000 and i + total <= len(blob):
            out.append((i, total))
        off = i + 4


def dtb_props(dtb):
    props = {}
    fdtget = shutil.which('fdtget')
    if not fdtget:
        return {'fdtget': 'missing'}
    with tempfile.NamedTemporaryFile(suffix='.dtb', delete=False) as fh:
        fh.write(dtb)
        path = fh.name
    try:
        for node, key in (('/chosen', 'bootargs'), ('/chosen', 'linux,initrd-start'),
                          ('/chosen', 'linux,initrd-end'), ('/', 'model')):
            res = subprocess.run([fdtget, path, node, key],
                                 capture_output=True, text=True)
            props['%s:%s' % (node, key)] = res.stdout.strip() or res.stderr.strip()
    finally:
        os.unlink(path)
    return props


def cpio_heads(blob):
    heads, off = [], 0
    while len(heads) < 6:
        i = blob.find(b'070701', off)
        if i < 0:
            break
        nfields = int(blob[i + 94:i + 102], 16)
        heads.append((hex(i), blob[i + 110:i + 110 + nfields].decode('utf-8', 'replace')))
        off = i + 6
    return heads


def inspect(path):
    data = open(path, 'rb').read()
    ks, rds = read32(data, 8), read32(data, 0xC)
    kb = data[0x1000:0x1000 + ks]
    tail = len(kb.rstrip(b'\0'))
    out = {'image': path, 'size': len(data), 'magic': data[:8].decode('latin1'),
           'kernel_size': hex(ks), 'ramdisk_size': hex(rds),
           'payload_tail': hex(tail), 'avb_footer': b'AVBf' in data[-512:]}
    w4 = read32(kb, 4)
    if is_branch(w4):
        entry = dec_branch(w4, 4)
        w0, w1 = read32(kb, entry), read32(kb, entry + 4)
        out.update({'entry': hex(entry),
                    'entry_word0': hex(w0), 'entry_target0': hex(dec_branch(w0, entry)) if is_branch(w0) else 'not-a-branch',
                    'entry_word1': hex(w1), 'entry_target1': hex(dec_branch(w1, entry + 4)) if is_branch(w1) else 'not-a-branch'})
    out['payload_head'] = kb[:16].hex()
    out['image_size_field'] = hex(struct.unpack_from('<Q', kb, 0x10)[0])
    out['magic_at_0x38'] = kb[0x38:0x3c].decode('latin1')
    for i, total in dtb_candidates(kb):
        out['dtb@%s' % hex(i)] = {'len': hex(total),
                                  'cpio_heads_in_dtb_gap': None,
                                  **dtb_props(kb[i:i + total])}
    out['cpio_heads'] = cpio_heads(kb)
    gap = kb[tail:ks]
    out['zero_gap_after_payload'] = hex(len(gap)) if set(gap) <= {0} else 'NON-ZERO'
    return out


def main():
    for path in sys.argv[1:]:
        print('== %s' % path)
        rep = inspect(path)
        for key, value in rep.items():
            if key == 'image':
                continue
            print('  %-24s %s' % (key, json.dumps(value) if not isinstance(value, str) else value))


if __name__ == '__main__':
    import json
    main()
