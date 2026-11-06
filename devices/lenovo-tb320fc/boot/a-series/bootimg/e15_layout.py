"""Shared E15 image layout: mainline Image + appended stub + appended DTB."""
import os
import struct

B = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(B, 'armada-boot', 'vmlinuz')
DTB = os.path.join(B, 'e15', 'e15.dtb')
DTB_INFO = os.path.join(B, 'e15', 'e15.dtb.info')

FB_BASE, FB_BYTES = 0xB8000000, 0x2B00000
STUB_LEN = 0x1000


def al4k(n):
    return (n + 4095) // 4096 * 4096


def read32(data, off):
    return struct.unpack_from('<I', data, off)[0]


def enc_branch(pc, to, link=False):
    assert (to - pc) % 4 == 0, (hex(pc), hex(to))
    imm = (to - pc) // 4
    assert -0x2000000 <= imm < 0x2000000, hex(imm)
    return (0x94000000 if link else 0x14000000) | (imm & 0x3FFFFFF)


def dec_branch(word, pc):
    assert (word >> 26) in (0b000101, 0b100101), hex(word)
    imm = word & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return pc + imm * 4


def entry_point(blob):
    """arm64 Image header: code1 is the branch the bootloader follows."""
    word = read32(blob, 4)
    return dec_branch(word, 4), word


def image_size(blob):
    return struct.unpack_from('<Q', blob, 0x10)[0]


def placeholder_offset():
    for line in open(DTB_INFO, encoding='utf-8'):
        if line.startswith('placeholder_off='):
            return int(line.split('=', 1)[1])
    raise AssertionError('no placeholder_off in %s' % DTB_INFO)


def layout():
    with open(IMG, 'rb') as fh:
        head = fh.read(0x1000)
    assert head[0x38:0x3c] == b'ARMd', 'not an arm64 Image'
    img_len = os.path.getsize(IMG)
    stub_off = al4k(max(image_size(head), img_len))
    dtb_off = stub_off + STUB_LEN
    return {
        'img_len': img_len,
        'image_size': image_size(head),
        'entry': entry_point(head)[0],
        'stub_off': stub_off,
        'stub_len': STUB_LEN,
        'dtb_off': dtb_off,
        'dtb_len': os.path.getsize(DTB),
        'ph_off': placeholder_offset(),
        'fb_base': FB_BASE,
        'fb_bytes': FB_BYTES,
    }
