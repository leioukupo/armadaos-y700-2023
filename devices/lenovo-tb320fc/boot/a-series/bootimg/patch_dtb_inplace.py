"""Byte-preserving device-tree property patcher for the A-slot payload container.

The payload kernel Image carries an appended DTB, and the A-slot handover stub
writes the kshim-append reg through a compile-time byte offset inside that DTB.
A payload DT edit therefore has to keep totalsize and every struct offset
identical, so dtc re-compilation is out: we only rewrite the value bytes of an
existing string property and NUL-pad the tail of the old value region when the
new value is shorter. The property length field stays as it was, which keeps the
next token exactly where the factory image had it.

That padding is legal to the kernel, not just to libfdt:
__of_device_is_status() only requires strnlen(value, statlen) < statlen and then
strcmp() against "okay"/"ok", so a 9-byte property holding "okay" followed by
NUL padding still reads as "okay". dtc prints a "property is not a string"
warning for it; the payload kernel does not care.
"""
import hashlib
import json
import struct
import sys

BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9


def walk(buf):
    (magic, totalsize, off_struct, off_strings, off_rsvmap, version,
     last_comp, bootcpu, size_strings, size_struct) = struct.unpack('>10I', buf[:40])
    if magic != 0xd00dfeed:
        raise ValueError('bad magic')
    if totalsize != len(buf):
        raise ValueError('totalsize %d != len %d' % (totalsize, len(buf)))
    if version < 16:
        raise ValueError('unsupported version %d' % version)
    strings = buf[off_strings:off_strings + size_strings]

    def sname(off):
        end = strings.index(b'\0', off)
        return strings[off:end].decode()

    out, path = [], []
    pos, stop = off_struct, off_struct + size_struct
    while pos < stop:
        token, = struct.unpack('>I', buf[pos:pos + 4])
        pos += 4
        if token == BEGIN_NODE:
            zero = buf.index(b'\0', pos)
            path.append(buf[pos:zero].decode())
            pos = (zero + 4) & ~3
            out.append(('node', '/'.join(path), pos))
        elif token == END_NODE:
            path.pop()
            out.append(('endnode', '/'.join(path), pos))
        elif token == PROP:
            length, nameoff = struct.unpack('>II', buf[pos:pos + 8])
            pos += 8
            out.append(('prop', sname(nameoff), pos, length))
            pos = (pos + length + 3) & ~3
        elif token == NOP:
            continue
        elif token == END:
            break
        else:
            raise ValueError('bad token %d at %d' % (token, pos - 4))
    return out


def find_dtb(data):
    hits, pos = [], 0
    while True:
        i = data.find(b'\xd0\x0d\xfe\xed', pos)
        if i < 0:
            return hits
        pos = i + 4
        if i + 40 > len(data):
            continue
        size = struct.unpack('>I', data[i + 4:i + 8])[0]
        if not (4096 < size < 8 * 1024 * 1024) or i + size > len(data):
            continue
        try:
            walk(data[i:i + size])
        except Exception:
            continue
        hits.append((i, size))


def main(argv):
    if len(argv) < 3:
        print('usage: patch_dtb_inplace.py IN.img OUT.img node=value ...')
        return 2
    src, dst = argv[1], argv[2]
    want = {}
    for arg in argv[3:]:
        node, _, value = arg.partition('=')
        if not node or not value:
            print('BAD_SPEC %r' % arg)
            return 2
        want[node] = value

    original = open(src, 'rb').read()
    data = bytearray(original)
    hits = find_dtb(data)
    if len(hits) != 1:
        print('DTB_CANDIDATES %d %s' % (len(hits), hits))
        return 1
    base, size = hits[0]

    before = walk(bytes(data[base:base + size]))
    plan = []
    for index, entry in enumerate(before):
        if entry[0] != 'node':
            continue
        name = entry[1].rsplit('/', 1)[-1]
        if name not in want:
            continue
        for follow in before[index + 1:]:
            if follow[0] == 'node':
                break
            if follow[0] == 'prop' and follow[1] == 'status':
                plan.append((entry[1], follow[2], follow[3], want[name]))
                break
    if len(plan) != len(want):
        print('PROPS_FOUND %d WANT %d' % (len(plan), len(want)))
        return 1

    report = {'image': src, 'dtb_off': base, 'dtb_size': size,
              'dtb_md5_before': hashlib.md5(bytes(data[base:base + size])).hexdigest(),
              'edits': []}
    for path, data_off, length, value in plan:
        new = value.encode() + b'\0'
        if len(new) > length:
            print('NO_ROOM %s prop_len %d value %r' % (path, length, value))
            return 1
        old = bytes(data[base + data_off:base + data_off + length])
        patch = new + b'\0' * (length - len(new))
        data[base + data_off:base + data_off + length] = patch
        report['edits'].append({
            'node': path, 'prop_data_off': base + data_off, 'prop_len': length,
            'old': old.decode('latin1'), 'new': patch.decode('latin1'),
            'changed_bytes': sum(1 for a, b in zip(old, patch) if a != b)})

    after = walk(bytes(data[base:base + size]))
    if after != before:
        print('LAYOUT_CHANGED')
        return 1
    if len(data) != len(original):
        print('IMAGE_LEN_CHANGED')
        return 1
    diff = [i for i, (a, b) in enumerate(zip(original, data)) if a != b]
    report['total_diff_bytes'] = len(diff)
    report['diff_span'] = [min(diff), max(diff)] if diff else []
    report['dtb_md5_after'] = hashlib.md5(bytes(data[base:base + size])).hexdigest()
    report['outside_dtb_diffs'] = sum(1 for i in diff if not base <= i < base + size)

    open(dst, 'wb').write(bytes(data))
    print(json.dumps(report, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
