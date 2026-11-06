#!/usr/bin/env python3
"""E15 = mainline 7.2.6 Image + handover stub + our boot DTB, packed into the
stock boot_b container and re-signed with the stock AVB parameters (NONE).

The kernel entry's first BL is replaced by a branch to the stub appended past
_end; the stub paints the splash region, fixes up the appended DTB's reserved
region, hands that DTB over in x0 and resumes the kernel at entry+4.
"""
import hashlib
import importlib.util
import json
import os
import struct
import subprocess
import sys

B = '/tmp/y700/a1'
AB = os.path.join(B, 'armada-boot')
STOCK = '/tmp/y700/a1/boot_b-stock.img'
STUBBIN = '/tmp/y700/a1/e15/e15_stub.bin'
AVBTOOL = '/tmp/y700/a1/avbtool.py'
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(AB, 'boot-b-e15.img')
PSIZE = 96 * 1024 * 1024

sys.path.insert(0, B)
from e15_layout import DTB, IMG, al4k, dec_branch, enc_branch, layout, read32  # noqa: E402

# paint prologue: add x15, x11, x12
PAINT_PROLOGUE = 0x8B0C016F
MAGIC = bytes.fromhex('deadbeefcafebabe')

text = lambda v: v if isinstance(v, str) else bytes(v).decode('utf-8')


def avb_source(image):
    spec = importlib.util.spec_from_file_location('_avbtool', AVBTOOL)
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(mod)
    handler = mod.ImageHandler(image, read_only=True)
    try:
        _f, header, descs, _t = mod.Avb()._parse_image(handler)
    finally:
        handler._image.close()
    hashes = [d for d in descs if isinstance(d, mod.AvbHashDescriptor)]
    assert len(hashes) == 1, hashes
    props = [(text(d.key), text(d.value)) for d in descs
             if not isinstance(d, mod.AvbHashDescriptor)]
    h = hashes[0]
    return {'partition_name': text(h.partition_name),
            'hash_algorithm': text(h.hash_algorithm),
            'salt': bytes(h.salt).hex(),
            'rollback_index': getattr(header, 'rollback_index', 0),
            'rollback_index_location': getattr(header, 'rollback_index_location', 0),
            'descriptor_flags': getattr(h, 'flags', 0), 'props': props}


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


L = layout()
stub = bytearray(open(STUBBIN, 'rb').read())
dtb = open(DTB, 'rb').read()
assert len(stub) <= L['stub_len'], hex(len(stub))
assert len(dtb) <= L['stub_len'] * 64, len(dtb)

slots = [i for i in range(0, len(stub) - 7, 4) if stub[i:i + 8] == b'\0' * 8]
assert len(slots) == 1, [hex(x) for x in slots]
slot = slots[0]
assert struct.unpack_from('<I', stub, slot + 8)[0] == PAINT_PROLOGUE, 'slot is not the tail of hook'

blob = bytearray(open(IMG, 'rb').read())
assert len(blob) == L['img_len']
entry = L['entry']
w0, w1 = read32(blob, entry), read32(blob, entry + 4)
assert w0 >> 26 == 0b100101 and w1 >> 26 == 0b100101, (hex(w0), hex(w1))
displaced = dec_branch(w0, entry)

struct.pack_into('<I', stub, slot, enc_branch(L['stub_off'] + slot, displaced, link=True))
struct.pack_into('<I', stub, slot + 4, enc_branch(L['stub_off'] + slot + 4, entry + 4))

ksize_new = L['dtb_off'] + al4k(len(dtb))
blob += b'\0' * (ksize_new - len(blob))
blob[L['stub_off']:L['stub_off'] + len(stub)] = stub
blob[L['dtb_off']:L['dtb_off'] + len(dtb)] = dtb
struct.pack_into('<I', blob, entry, enc_branch(entry, L['stub_off']))
assert blob[L['dtb_off'] + L['ph_off']:L['dtb_off'] + L['ph_off'] + 8] == MAGIC, \
    'kshim-append placeholder missing; the stub patches it at runtime'

stock = open(STOCK, 'rb').read()
assert stock[:8] == b'ANDROID!'
# 0x10 is os_version in this GKI-style header; the whole header page is copied
hdr = bytearray(stock[:0x1000])
ksize, rdsize = read32(stock, 8), read32(stock, 0xC)
ramdisk = stock[0x1000 + al4k(ksize):0x1000 + al4k(ksize) + rdsize]
assert ramdisk[:4] == b'\x02\x21\x4c\x18', ramdisk[:4].hex()
struct.pack_into('<I', hdr, 8, ksize_new)

if os.path.exists(OUT):
    os.unlink(OUT)
with open(OUT, 'wb') as fh:
    fh.write(bytes(hdr) + bytes(blob) + ramdisk + b'\0' * (al4k(rdsize) - len(ramdisk)))

src = avb_source(STOCK)
args = [sys.executable, '-B', AVBTOOL, 'add_hash_footer', '--image', OUT,
        '--partition_size', str(PSIZE), '--partition_name', 'boot',
        '--algorithm', 'NONE', '--hash_algorithm', src['hash_algorithm'],
        '--salt', src['salt'], '--rollback_index', str(src['rollback_index']),
        '--rollback_index_location', str(src['rollback_index_location'])]
if src['descriptor_flags'] & 1:
    args.append('--do_not_use_ab')
for k, v in src['props']:
    args += ['--prop', '%s:%s' % (k, v)]
subprocess.run(args, check=True)

final = open(OUT, 'rb').read()
fk = read32(final, 8)
kb = final[0x1000:0x1000 + fk]
rep = {
    'out': OUT, 'sha256': sha(OUT), 'size': len(final),
    'kernel_size': hex(fk), 'ramdisk_size': hex(read32(final, 0xC)),
    'entry': hex(entry), 'entry_word_stock': hex(w0),
    'entry_word_new': hex(read32(kb, entry)),
    'entry_target_new': hex(dec_branch(read32(kb, entry), entry)),
    'displaced_bl_target': hex(displaced),
    'entry_word2_stock': hex(w1),
    'stub_off': hex(L['stub_off']), 'stub_len': hex(len(stub)),
    'stub_bl_slot': hex(slot),
    'stub_bl_target': hex(dec_branch(read32(kb, L['stub_off'] + slot), L['stub_off'] + slot)),
    'stub_b_target': hex(dec_branch(read32(kb, L['stub_off'] + slot + 4), L['stub_off'] + slot + 4)),
    'dtb_off': hex(L['dtb_off']), 'dtb_len': hex(len(dtb)),
    'dtb_placeholder_abs': hex(L['dtb_off'] + L['ph_off']),
    'image_size_field': hex(L['image_size']),
    'markers': {'red_top_64k': 'stub started, died before finishing',
                'green_all': 'stub finished, kernel took over',
                'logo_untouched': 'stub never ran'},
    'avb_props': src['props'],
}
assert rep['entry_target_new'] == hex(L['stub_off'])
assert rep['stub_bl_target'] == hex(displaced)
assert rep['stub_b_target'] == hex(entry + 4)
assert fk == ksize_new
assert kb[L['dtb_off'] + L['ph_off']:][:8] == MAGIC
report = os.path.join(AB, os.path.splitext(os.path.basename(OUT))[0] + '.report.json')
open(report, 'w').write(json.dumps(rep, indent=2))
print(json.dumps(rep, indent=2))


