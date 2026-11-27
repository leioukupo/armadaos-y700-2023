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
# Pinning to the side that has no firmware bricks the board, so --pin b is gated.
# A Lenovo EDL rom writes real images only into the *_a copies, since rawprogram4.xml
# carries filename="" for uefi_b/tz_b/abl_b/boot_b/devcfg_b, leaving them zeroed.
# Marking *_a dont-boot-again right after a rom restore forces XBL to load zeroed _b
# firmware and XBL itself crashes, landing the board in PBL crashdump (USB 05c6:900e).
# Crashdump Sahara is read-only (loader upload -> 0x93011004, command mode -> NAK), and
# with no ABL there is no fastboot and no recovery: volume keys are not an EDL trigger
# on this model, so the only way back is a hardware EDL short. See PROGRESS A226.
#
# undo-pin.sh is written next to the new tables so the pre-pin dumps go back verbatim.
# The primary dump starts at LBA0 and holds the protective MBR, so it must be written
# with ws 0 -- ws 1 would overwrite the GPT header with MBR bytes.
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
import os
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
    return buf, off, dict(entba=entba, cnt=cnt, esz=esz, lu=lu, alt=alt, first=my - off // SEC)


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


def undo(work):
    # Write the firehose commands that put the pre-pin LUN4 GPT back byte for byte.
    _, _, H = load("%s/gptbak/prim4.bin" % work)
    back = H["alt"] - 4
    lines = [
        "#!/bin/sh",
        "# Restore the LUN4 GPT exactly as captured before gpt-slice-pin.py ran.",
        "# prim4.bin starts at LBA0 and holds the protective MBR, hence ws 0 is required.",
        "# Read the table first: a GPT header in the read-back proves we are in firehose/UFS mode,",
        "# not in the read-only crashdump path, where --memory silently dumps DDR instead.",
        "set -e",
        ": ${LOADER:?set LOADER to xbl_s_devprg_ns.melf}",
        "GPT=${GPTDIR:-gptbak}",
        "EDL=${EDL:-edl.py --loader=$LOADER --memory=ufshcd}",
        "$EDL rs 0 6 /tmp/check_prim4.bin --lun=4",
        "dd if=/tmp/check_prim4.bin bs=4096 skip=1 count=1 2>/dev/null | grep -q EFI || exit 1",
        "$EDL ws 0 $GPT/prim4.bin --lun=4",
        "$EDL ws %d $GPT/back4.bin --lun=4",
        "$EDL rs 0 6 /tmp/ok_prim4.bin --lun=4",
        "cmp /tmp/ok_prim4.bin $GPT/prim4.bin",
        "$EDL rs %d 5 /tmp/ok_back4.bin --lun=4",
        "cmp /tmp/ok_back4.bin $GPT/back4.bin",
        "edl.py --loader=$LOADER reset",
        "echo GPT_RESTORED_AND_VERIFIED",
    ]
    path = "%s/undo-pin.sh" % work
    with open(path, "w", newline="\n") as fh:
        fh.write(("\n".join(lines) % (back, back)) + "\n")
    os.chmod(path, 0o755)
    print("undo-pin.sh written, LUN4 backup entries start at LBA%d" % back)


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
ap.add_argument('--i-verified-b-firmware', action='store_true',
                help='required for --pin b: assert the *_b firmware partitions exist')
a = ap.parse_args()

reslice(a.dir, a.ref_gpt, a.userdata_end, a.lr_start, a.lr_end)
if a.pin:
    p4 = '%s/gptbak/prim4.bin' % a.dir
    b4 = '%s/gptbak/back4.bin' % a.dir
    if not (open(p4, 'rb').read() and open(b4, 'rb').read()):
        raise SystemExit('no LUN4 dumps under %s/gptbak' % a.dir)
    if a.pin == "b" and not a.i_verified_b_firmware:
        raise SystemExit(
            "--pin b needs --i-verified-b-firmware: after a Lenovo EDL rom restore the *_b "
            "firmware (uefi_b/tz_b/abl_b/devcfg_b) is zeroed, so marking *_a dont-boot-again "
            "makes XBL crash into a read-only PBL crashdump that only a hardware EDL short "
            "can reach (PROGRESS A226).")
    pin(a.dir, a.pin, p4, b4)
    undo(a.dir)
