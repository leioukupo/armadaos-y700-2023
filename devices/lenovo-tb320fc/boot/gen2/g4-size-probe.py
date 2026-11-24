#!/usr/bin/env python3
"""g4: is the boot-partition copy window what kills the 82 MB Gen 2 blob?

Re-pack the known-good `boot-b-a147.img` (a-series E15 layout, boots on the
device) byte-for-byte and raise only the container's `kernel_size`, to the value
`boot-a-g3.img` carried (0x51f6000 = 82.0 MiB). Nothing moves: the Image, the
handover stub at image_size and the appended DTB keep their offsets, the extra
room is zero padding between the real payload tail and the stock debug ramdisk,
and the AVB footer is re-attached with the source image's own parameters
(algorithm NONE).

  still boots -> the copy window is not the ceiling; the suspect is gen2's
                 appended-initrd layer, its DTB surgery, or Freedom 7.2.6.
  crashdump   -> the ~60-80 MB window is real; the Freedom Image has to be
                 slimmed under ~57 MB, or stub/DTB/initrd has to live inside
                 the Image the way the a-series build does it.
"""
import hashlib
import importlib.util
import json
import os
import struct
import subprocess
import sys

PSIZE = 96 * 1024 * 1024
TARGET = 0x51F6000  # kernel_size of boot-a-g3.img, the image that crashdumped
SRC = '/root/y700-artifacts/boot-b-a147.img'
OUT = '/srv/y700/g4/boot-a-g4.img'
AVBTOOL = '/root/y700-artifacts/avbtool.py'

text = lambda v: v if isinstance(v, str) else bytes(v).decode('utf-8')


def al4k(n):
    return (n + 4095) // 4096 * 4096


def read32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def dec_branch(word, pc):
    assert word >> 26 == 0b100101, hex(word)
    imm = word & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return pc + imm * 4


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


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
    props = [(text(d.key), text(d.value))
             for d in descs if not isinstance(d, mod.AvbHashDescriptor)]
    h = hashes[0]
    return {'partition_name': text(h.partition_name),
            'hash_algorithm': text(h.hash_algorithm),
            'salt': bytes(h.salt).hex(),
            'rollback_index': getattr(header, 'rollback_index', 0),
            'rollback_index_location': getattr(header, 'rollback_index_location', 0),
            'descriptor_flags': getattr(h, 'flags', 0), 'props': props}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else SRC
    out = sys.argv[2] if len(sys.argv) > 2 else OUT
    avbtool = sys.argv[3] if len(sys.argv) > 3 else AVBTOOL

    data = open(src, 'rb').read()
    assert data[:8] == b'ANDROID!', data[:8]
    assert len(data) == PSIZE, len(data)
    hdr = bytearray(data[:0x1000])
    ks, rds = read32(data, 8), read32(data, 0xC)
    kb = data[0x1000:0x1000 + ks]
    rd = data[0x1000 + al4k(ks):0x1000 + al4k(ks) + rds]
    assert rd[:4] == b'\x02\x21\x4c\x18', rd[:4].hex()
    tail = len(kb.rstrip(b'\0'))
    assert ks < TARGET <= PSIZE - 0x1000 - al4k(rds), (hex(ks), hex(TARGET))
    assert tail <= ks

    entry = dec_branch(read32(kb, 4), 4)
    w0, w1 = read32(kb, entry), read32(kb, entry + 4)

    struct.pack_into('<I', hdr, 8, TARGET)
    blob = kb + b'\0' * (TARGET - len(kb))
    if os.path.exists(out):
        os.unlink(out)
    with open(out, 'wb') as fh:
        fh.write(bytes(hdr) + blob + rd + b'\0' * (al4k(rds) - len(rd)))

    src_avb = avb_source(src) if os.path.exists(avbtool) else None
    if src_avb:
        args = [sys.executable, '-B', avbtool, 'add_hash_footer', '--image', out,
                '--partition_size', str(PSIZE), '--partition_name', 'boot',
                '--algorithm', 'NONE', '--hash_algorithm', src_avb['hash_algorithm'],
                '--salt', src_avb['salt'],
                '--rollback_index', str(src_avb['rollback_index']),
                '--rollback_index_location', str(src_avb['rollback_index_location'])]
        if src_avb['descriptor_flags'] & 1:
            args.append('--do_not_use_ab')
        for k, v in src_avb['props']:
            args += ['--prop', '%s:%s' % (k, v)]
        subprocess.run(args, check=True)

    final = open(out, 'rb').read()
    fk = read32(final, 8)
    fkb = final[0x1000:0x1000 + fk]
    assert len(final) == PSIZE, len(final)
    assert fk == TARGET, (hex(fk), hex(TARGET))
    assert fkb[:tail] == kb[:tail], 'payload bytes moved'
    assert read32(fkb, entry) == w0 and read32(fkb, entry + 4) == w1
    assert set(fkb[tail:TARGET]) == {0}, 'padding is not pure zero'
    assert final[0x1000 + al4k(fk):0x1000 + al4k(fk) + rds] == rd, 'ramdisk moved'
    assert b'AVBf' in final[-512:], 'no AVB footer'

    rep = {'src': src, 'src_sha256': sha256(src), 'out': out, 'sha256': sha256(out),
           'size': len(final), 'kernel_size_old': hex(ks), 'kernel_size_new': hex(fk),
           'payload_tail': hex(tail), 'ramdisk_size': hex(rds),
           'entry': hex(entry), 'entry_word0': hex(w0), 'entry_word1': hex(w1),
           'entry_target': hex(dec_branch(w0, entry)),
           'avb_props': src_avb['props'] if src_avb else None,
           'single_variable': 'kernel_size only; payload, stub, DTB and ramdisk offsets unchanged'}
    report = os.path.join(os.path.dirname(out),
                          os.path.splitext(os.path.basename(out))[0] + '.report.json')
    open(report, 'w').write(json.dumps(rep, indent=2))
    print(json.dumps(rep, indent=2))


if __name__ == '__main__':
    main()
