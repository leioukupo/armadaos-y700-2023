#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline TB320FC (Lenovo Legion Y700 Gen 2, SM8475/CapeP) boot packager.

The Gen2 stock boot image is a raw, unsigned-style v4 "ANDROID!" container
(96 MiB) whose kernel blob is a Qualcomm MZ/PE-style wrapper around a flat
ARM64 image:

  * container header: magic @0x00, kernel_size @0x08, debug-ramdisk
    size @0x0C / load address @0x10, header_size @0x14 (1584), version
    @0x28 (4); there is no cmdline field in this variant.
  * the kernel blob starts at 0x1000 with the ARM64 Linux image header
    (code0 = the EFI signature NOP that spells 'MZ', code1, text_offset
    @0x08, image_size @0x10, flags @0x18, magic 'ARMd' @0x38, PE header
    offset @0x3c = 0x40) plus the PE/COFF headers the EFI stub shares
    with it.  The section table is real (.text at 0x10000, .data at
    0x2730000) and every section has VirtualAddress == PointerToRawData,
    so inside the mapped range file offset equals virtual offset.
  * the entry the bootloader really reaches is the ARM64 header
    trampoline target - the branch in code1, blob offset 0x2470000
    (primary_entry) - not the PE entry RVA 0x24703e8 (efi_pe_entry).
    Stock Android on this device has no /sys/firmware/efi and text_offset
    is 0, so the loader uses the legacy ARM64 handover and efi_pe_entry
    is dead code: patching it leaves the attached shim unreached, which
    is what the HALT experiment on hardware showed.
  * after the 4 KiB-aligned kernel slot the stock image keeps a
    debug-ramdisk payload (header 0x0C/0x10) and, at the end, an AVB
    footer (algorithm NONE) with its vbmeta.  The repack grows the
    kernel slot over the debug-ramdisk region, so that payload is
    dropped in the emitted image (header fields stay untouched); the
    new vbmeta is placed by avbtool at the new original_image_size.

The kShimC handoff therefore patches the executed entry site (the ARM64
code1 branch target) instead of offset 0 of the blob:

  entry+0x00  BL <runtime>          (only instruction overwritten here)
  entry+0x10  u64 packed image size (relative to the entry site)
  entry+0x20  u64 manifest offset   (relative)
  entry+0x28  u64 manifest size     (relative)
  entry+0x30  u64 shim offset       (relative)

The runtime (kshim-success-source, tb320fc_android_defconfig) is
self-relocating and reads exactly those slots: linux_base is the BL
instruction address (LR-4), so the manifest, the packed size bound and the
shim offset are all relative to the entry site.  The five 64-bit backup
slots in the manifest header preserve the original entry-site chunks
(+0x00..0x07, +0x10..0x17, +0x20..0x27, +0x28..0x2f, +0x30..0x37) so the
Gen2 kShim patch can restore the prologue and branch to entry+0.

Packed kernel layout (offsets relative to the kernel blob start):

  0x00000000 .. 0x02c9a3e4  stock kernel blob (entry patched in place)
  0x02c9a3e4 .. 0x0309a3e4  4 MiB kShimC runtime
  0x0309a3e4 ..             manifest (magic 0x464D504B, v0.1, 2 entries)

Only the kernel_size field (0x08) of the container header changes.  A stock
image with an AVB footer is re-sealed with the official avbtool (metadata
algorithm NONE, original salt/properties), exactly like the Gen5
repack_boot_v4.py flow.  The script is stdlib-only and offline: no device
access, no flashing.  hardware_tested is always false.
"""

import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys

sys.dont_write_bytecode = True

BOOT_SIZE = 96 * 1024 * 1024
HDR = 4096
HDR_KERN_SIZE_OFF = 8
HDR_KERN_SIZE_END = 12
HDR_HDR_SIZE_OFF = 0x14
HDR_VERSION_OFF = 0x28
MAGIC = b"ANDROID!"
HDR_SIZE_EXPECTED = 1584
PE_SIG_SCAN_END = 0x2000
PAGE_ALIGN = 4096
RAMDISK_MAGIC_LZ4 = b"\x02\x21\x4c\x18"
PE_MACHINE_ARM64 = 0xAA64
PE32PLUS_MAGIC = 0x20B
PE_SECTION_HDR_SIZE = 40
PE_IMAGE_BASE_OFF = 0x18
PE_SECTION_ALIGN_OFF = 0x20
PE_FILE_ALIGN_OFF = 0x24
PE_SIZE_OF_IMAGE_OFF = 0x38
PE_SIZE_OF_HEADERS_OFF = 0x3C
PE_NUM_SECTIONS_OFF = 0x06
PE_SEC_CHARS_RUN = 0xE0000060
RUNTIME_SECTION_NAME = b".kshim"
ARM64_MAGIC = b"ARMd"
ARM64_HDR_CODE0 = 0x00
ARM64_HDR_CODE1 = 0x04
ARM64_HDR_TEXT_OFFSET = 0x08
ARM64_HDR_IMAGE_SIZE = 0x10
ARM64_HDR_FLAGS = 0x18
ARM64_HDR_MAGIC = 0x38
ARM64_HDR_PE_OFF = 0x3C
ARM64_EFI_SIG_NOP = 0x91005A4D
ARM64_FLAG_PHYS_ALIGN = 3
RUNTIME_SIZE = 4 * 1024 * 1024
MANIFEST_MAGIC = 0x464D504B
MANIFEST_VERSION = (0, 1)
# A Gen2 code1 runtime carries its own base-image contract; the repacker
# finds it by scanning for magic+version followed by four zero quads.
RUNTIME_CONTRACT_MAGIC = 0x5452504B  # "KPRT"
RUNTIME_CONTRACT_VERSION = 1
RUNTIME_CONTRACT_BYTES = 40
ARM64_HDR_CODE1 = 0x04
MANIFEST_HEADER_SIZE = 60
MANIFEST_ENTRY_SIZE = 56
MANIFEST_ENTRY_ALIGN = 4
MF_TYPE_LINUX = 1
MF_TYPE_SHIM = 3
FLAG_BASE = 1
FLAG_EXEC = 4
BL_RANGE = 0x8000000
AVB_MAGIC = b"AVBf"
DEFAULT_BASE_NAME = "原厂 Android"
DEFAULT_SHIM_NAME = "Attached Shim"
DEFAULT_TIMEOUT_MS = 8000


class StageError(Exception):
    def __init__(self, stage, message):
        super().__init__(message)
        self.stage = stage
        self.message = message


STAGE = "init"
CHECKS = []
COMMANDS = []


def set_stage(stage):
    global STAGE
    STAGE = stage


def check(name, condition, detail=""):
    CHECKS.append({"check": name, "ok": bool(condition), "detail": detail})
    if not condition:
        raise StageError(STAGE, name + ((": " + detail) if detail else ""))


def le32(buf, offset):
    return struct.unpack_from("<I", buf, offset)[0]


def le64(buf, offset):
    return struct.unpack_from("<Q", buf, offset)[0]


def align_up(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_bytes(path, label):
    with open(path, "rb") as f:
        return f.read()


def run(cmd, name, stdout_path=None):
    COMMANDS.append({"name": name, "argv": [str(c) for c in cmd]})
    proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if stdout_path:
        with open(stdout_path, "w", encoding="utf-8") as f:
            f.write(proc.stdout)
            if proc.stderr:
                f.write("\n--- stderr ---\n")
                f.write(proc.stderr)
    check("cmd:" + name, proc.returncode == 0,
          "rc=%d stderr=%s" % (proc.returncode, (proc.stderr or "")[:300]))
    return proc


# ---------------------------------------------------------------------------
# Container + PE parsing
# ---------------------------------------------------------------------------

def parse_boot_header(data):
    return {
        "magic": data[0:8],
        "kernel_size": le32(data, HDR_KERN_SIZE_OFF),
        # Gen2 variant: 0x0C is the debug-ramdisk size and 0x10 its load
        # address; the content slot follows the kernel slot.  Both stay
        # untouched by the packer.
        "ramdisk_size": le32(data, 0x0C),
        "ramdisk_load": le32(data, 0x10),
        "header_size": le32(data, HDR_HDR_SIZE_OFF),
        "version": le32(data, HDR_VERSION_OFF),
    }


def parse_avb_footer(data):
    if len(data) < 64 or data[-64:-60] != AVB_MAGIC:
        return None
    _m, maj, mnr, ois, vbo, vbs, _r = struct.unpack_from(
        ">4sIIQQQ28s", data, len(data) - 64)
    if maj != 1:
        raise StageError("parse", "AVB footer major version %d" % maj)
    return {
        "major": maj,
        "minor": mnr,
        "original_image_size": ois,
        "vbmeta_offset": vbo,
        "vbmeta_size": vbs,
    }


def parse_pe(kernel):
    """Parse the Gen2 (SM8475) kernel wrapper.

    Real layout (verified on the stock boot_a.img):
      0x00  64-byte MZ stub (e_lfanew = 0x40)
      0x40  PE signature + 20-byte COFF header (machine 0xAA64, nsec 2,
            sizeofopt = 0 decoy)
      0x54  160-byte extended header:
            +0x00 u16 0x00A0  its own length
            +0x04 u16 0x020B  'PE32+' magic
            +0x0C u32 0x00350000  image-base-like decoy
            +0x14 u32            entry RVA  <- the real entry
      0xF4  decoy section table (not used for bounds)
    The loader flat-copies the kernel region and jumps to the entry RVA,
    so file offset equals virtual offset inside the blob."""
    check("pe:mz", kernel[0:2] == b"MZ", repr(kernel[0:2]))
    e_lfanew = le32(kernel, 0x3C)
    check("pe:lfanew", 0 < e_lfanew < 0x1000, "0x%x" % e_lfanew)
    sig_off = e_lfanew
    check("pe:sig", kernel[sig_off:sig_off + 4] == b"PE\x00\x00",
          "no PE signature at 0x%x" % sig_off)
    machine, nsec = struct.unpack_from("<HH", kernel, sig_off + 4)
    check("pe:machine", machine == PE_MACHINE_ARM64, "0x%04x" % machine)
    ext = sig_off + 20
    extlen = struct.unpack_from("<H", kernel, ext)[0]
    check("pe:extlen", extlen == 0xA0, "0x%x" % extlen)
    emagic = struct.unpack_from("<H", kernel, ext + 4)[0]
    check("pe:emagic", emagic == PE32PLUS_MAGIC, "0x%04x" % emagic)
    entry_rva = le32(kernel, ext + 0x14)
    check("pe:entry_rva", entry_rva != 0 and (entry_rva & 3) == 0
          and entry_rva < len(kernel),
          "0x%x (blob 0x%x)" % (entry_rva, len(kernel)))
    w0 = le32(kernel, entry_rva)
    check("pe:entry-not-branch", not is_branch(w0),
          "entry first word 0x%08x is a branch; Gen2 protocol requires a "
          "normal prologue" % w0)
    # The optional header starts right after the 20-byte COFF header, so
    # the fields below use real PE32+ offsets from there.
    opt = sig_off + 24
    section_align = le32(kernel, opt + PE_SECTION_ALIGN_OFF)
    file_align = le32(kernel, opt + PE_FILE_ALIGN_OFF)
    size_of_image = le32(kernel, opt + PE_SIZE_OF_IMAGE_OFF)
    size_of_headers = le32(kernel, opt + PE_SIZE_OF_HEADERS_OFF)
    check("pe:section-align", section_align in (0x1000, 0x10000),
          "0x%x" % section_align)
    check("pe:file-align", file_align in (0x200, 0x1000), "0x%x" % file_align)
    check("pe:size-of-headers", 0 < size_of_headers <= 0x10000,
          "0x%x" % size_of_headers)
    check("pe:size-of-image", size_of_headers < size_of_image <= len(kernel),
          "0x%x (blob 0x%x)" % (size_of_image, len(kernel)))
    sec_off = opt + extlen
    sections = []
    for index in range(nsec):
        at = sec_off + index * PE_SECTION_HDR_SIZE
        vsize, vaddr, rawsize, rawptr = struct.unpack_from(
            "<IIII", kernel, at + 8)
        sections.append({
            "name": kernel[at:at + 8].rstrip(b"\x00").decode("latin1"),
            "virtual_size": vsize, "virtual_address": vaddr,
            "raw_size": rawsize, "raw_pointer": rawptr,
        })
    check("pe:section-count", nsec > 0 and sec_off + nsec *
          PE_SECTION_HDR_SIZE <= len(kernel), "nsec=%d" % nsec)
    # VirtualAddress == PointerToRawData is what makes one offset valid for
    # both the file and the mapped image; a PE loader that maps by section
    # and a loader that flat-copies then agree inside SizeOfImage.
    check("pe:sections-flat",
          all(s["virtual_address"] == s["raw_pointer"] for s in sections),
          "; ".join("%s va=0x%x raw=0x%x" % (s["name"], s["virtual_address"],
                                             s["raw_pointer"])
                    for s in sections))
    check("pe:image-covers-sections",
          all(s["virtual_address"] + max(s["virtual_size"], s["raw_size"])
              <= size_of_image for s in sections),
          "size_of_image=0x%x" % size_of_image)
    last = len(kernel)
    while last > entry_rva and kernel[last - 1] == 0:
        last -= 1
    return {
        "sig_off": sig_off,
        "machine": machine,
        "section_count": nsec,
        "ext_off": ext,
        "ext_len": extlen,
        "ext_magic": emagic,
        "image_base": le64(kernel, ext + 0x0C),
        "entry_rva": entry_rva,
        "entry_word0": w0,
        "last_nonzero": last,
        "section_align": section_align,
        "file_align": file_align,
        "size_of_image": size_of_image,
        "size_of_headers": size_of_headers,
        "sec_off": sec_off,
        "sections": sections,
    }


def is_bl(word):
    return (word & 0xFC000000) == 0x94000000


def decode_b(word, at):
    imm26 = word & 0x03FFFFFF
    if imm26 & 0x02000000:
        imm26 -= 0x04000000
    return at + imm26 * 4


def parse_arm64_header(kernel, code1_target=None):
    """Parse the ARM64 Linux image header at the start of the kernel blob.

    head.S lays the header out as the EFI signature NOP ('MZ'), a branch
    into the kernel text, text_offset, image_size, flags, three reserved
    quads, the 'ARMd' magic and the PE header offset.  Modern kernels
    leave text_offset 0 and are entered at the image start, where that
    two-instruction trampoline branches into the text.  The branch in
    code1 is therefore the authoritative kernel entry point and the site
    the bootloader reaches, while the PE entry RVA is only used by an EFI
    handover this platform does not perform.
    """
    check("arm64:magic",
          kernel[ARM64_HDR_MAGIC:ARM64_HDR_MAGIC + 4] == ARM64_MAGIC,
          repr(kernel[ARM64_HDR_MAGIC:ARM64_HDR_MAGIC + 4]))
    code0 = le32(kernel, ARM64_HDR_CODE0)
    code1 = le32(kernel, ARM64_HDR_CODE1)
    check("arm64:code0-efi-nop", code0 == ARM64_EFI_SIG_NOP, "0x%08x" % code0)
    check("arm64:code1-is-b", is_branch(code1), "code1=0x%08x" % code1)
    entry = decode_b(code1, ARM64_HDR_CODE1)
    check("arm64:entry-in-blob",
          ARM64_HDR_CODE1 < entry < len(kernel) and (entry & 3) == 0,
          "0x%x (blob 0x%x)" % (entry, len(kernel)))
    entry_word = le32(kernel, entry)
    if code1_target is None:
        # primary_entry opens with a call that saves the boot arguments, so a
        # BL as the first word confirms this is the entry and not data.
        check("arm64:entry-is-call", is_bl(entry_word),
              "entry word 0x%08x at 0x%x is not a call" % (entry_word, entry))
    else:
        # code1 protocol: the header branch now leads to the runtime, and the
        # kernel entry keeps its own instructions untouched.
        check("arm64:code1-to-runtime", entry == code1_target,
              "code1 leads to 0x%x expected the runtime at 0x%x"
              % (entry, code1_target))
    text_offset = le64(kernel, ARM64_HDR_TEXT_OFFSET)
    image_size = le64(kernel, ARM64_HDR_IMAGE_SIZE)
    flags = le64(kernel, ARM64_HDR_FLAGS)
    pe_off = le32(kernel, ARM64_HDR_PE_OFF)
    check("arm64:text-offset-unused", text_offset in (0, entry),
          "text_offset=0x%x entry=0x%x" % (text_offset, entry))
    check("arm64:image-size", 0 < image_size <= len(kernel),
          "0x%x (blob 0x%x)" % (image_size, len(kernel)))
    check("arm64:pe-header-offset", pe_off == 0x40, "0x%x" % pe_off)
    check("arm64:phys-align-flag",
          (flags >> ARM64_FLAG_PHYS_ALIGN) & 1 == 1, "flags=0x%x" % flags)
    return {
        "code0": code0,
        "code1": code1,
        "entry": entry,
        "entry_word0": entry_word,
        "text_offset": text_offset,
        "image_size": image_size,
        "flags": flags,
        "pe_header_offset": pe_off,
    }


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

def build_manifest(backup, base_entry, shim_entry, timeout_ms=DEFAULT_TIMEOUT_MS):
    entries = [base_entry, shim_entry]
    out = struct.pack("<IHHIII", MANIFEST_MAGIC, MANIFEST_VERSION[0],
                       MANIFEST_VERSION[1], len(entries), 0, timeout_ms)
    out += struct.pack("<QQQQQ", *backup)
    for e in entries:
        name = e["name"].encode("utf-8")
        out += struct.pack(
            "<QQIIQIIIQI",
            e["offset"], e["size"], e["type"], e["flags"],
            e.get("load_address", 0), e.get("entry_offset", 0),
            e.get("dtb_index", 0), e.get("alignment", 1),
            e.get("copy_size_max", 0), len(name),
        )
        out += name
        pad = (MANIFEST_ENTRY_ALIGN - (MANIFEST_ENTRY_SIZE + len(name)) %
               MANIFEST_ENTRY_ALIGN) % MANIFEST_ENTRY_ALIGN
        out += b"\x00" * pad
    return out


def parse_manifest(buf, offset):
    magic, vmaj, vmin, count, default, timeout = struct.unpack_from(
        "<IHHIII", buf, offset)
    backup = struct.unpack_from("<QQQQQ", buf, offset + 20)
    entries = []
    cursor = offset + MANIFEST_HEADER_SIZE
    for _ in range(count):
        (e_off, e_size, e_type, e_flags, e_load, e_entry, e_dtb, e_align,
         e_copy, e_namelen) = struct.unpack_from("<QQIIQIIIQI", buf, cursor)
        name_bytes = buf[cursor + MANIFEST_ENTRY_SIZE:
                         cursor + MANIFEST_ENTRY_SIZE + e_namelen]
        record = (MANIFEST_ENTRY_SIZE + e_namelen + MANIFEST_ENTRY_ALIGN - 1) // \
            MANIFEST_ENTRY_ALIGN * MANIFEST_ENTRY_ALIGN
        entries.append({
            "offset": e_off, "size": e_size, "type": e_type,
            "flags": e_flags, "load_address": e_load,
            "entry_offset": e_entry, "dtb_index": e_dtb,
            "alignment": e_align, "copy_size_max": e_copy,
            "name": name_bytes.decode("utf-8"),
            "record_size": record,
        })
        cursor += record
    return {
        "magic": magic, "version": (vmaj, vmin), "count": count,
        "default": default, "timeout": timeout, "backup": backup,
        "entries": entries, "end": cursor,
    }



# ---------------------------------------------------------------------------
# Entry-site patching
# ---------------------------------------------------------------------------

def encode_bl(from_off, to_off):
    imm = to_off - from_off
    check("bl:range", -BL_RANGE < imm < BL_RANGE,
          "distance 0x%x out of BL range" % imm)
    imm26 = (imm >> 2) & 0x03FFFFFF
    return 0x94000000 | imm26


def decode_bl(word, from_off):
    imm26 = word & 0x03FFFFFF
    if imm26 & 0x02000000:
        imm26 -= 0x04000000
    return from_off + imm26 * 4


def is_branch(word):
    return (word & 0xFC000000) == 0x14000000


def patch_entry_site(kernel, linux_base, shim_off, manifest_size):
    """Return (patched_kernel, backup, layout) for the Gen2 protocol.

    linux_base is the executed kernel entry (the ARM64 code1 branch
    target); the shim recovers it as LR-4, so every contract slot is
    relative to that address."""
    manifest_off = shim_off + RUNTIME_SIZE
    packed_size = manifest_off + manifest_size - linux_base
    backup = [
        le64(kernel, linux_base + off)
        for off in (0x00, 0x10, 0x20, 0x28, 0x30)
    ]
    out = bytearray(kernel)
    bl = encode_bl(linux_base, shim_off)
    struct.pack_into("<I", out, linux_base + 0x00, bl)
    struct.pack_into("<Q", out, linux_base + 0x10, packed_size)
    struct.pack_into("<Q", out, linux_base + 0x20, manifest_off - linux_base)
    struct.pack_into("<Q", out, linux_base + 0x28, manifest_size)
    struct.pack_into("<Q", out, linux_base + 0x30, shim_off - linux_base)
    layout = {
        "linux_base": linux_base,
        "shim_off": shim_off,
        "manifest_off": manifest_off,
        "packed_size": packed_size,
    }
    return bytes(out), backup, layout


def patch_loader_bounds(kernel, pe, arm, shim_off, runtime_size,
                        manifest_size):
    '''Grow the loader view of the image so the appended runtime is mapped.

    Gen2 (SM8475) XBL/ABL sizes the kernel from the ARM64 image-header
    image_size field and from the PE SizeOfImage/section table, not from the
    Android boot-header kernel_size.  Appending the runtime past both left
    the entry BL branch running outside any mapped region and the device
    dropped straight into Qualcomm crashdump mode.

    Fix at the root: put the runtime on a SectionAlignment boundary, declare
    it as a real PE section with VirtualAddress == PointerToRawData (the
    invariant every stock section already satisfies), and grow image_size and
    SizeOfImage to the packed length, so a section-mapping loader and a
    flat-copying loader agree on one and the same address.  This mirrors the
    Gen5 pipeline (kshim-build-boot.py), which asserts image_size == len(raw)
    and stores the manifest contract in the raw ARM64 header.'''
    section_align = pe['section_align']
    file_align = pe['file_align']
    sig_off = pe['sig_off']
    opt = sig_off + 24
    nsec = pe['section_count']
    new_sec = pe['sec_off'] + nsec * PE_SECTION_HDR_SIZE
    target = align_up(shim_off + runtime_size + manifest_size, section_align)
    check('bounds:image-size-grows', target > arm['image_size'],
          '0x%x -> 0x%x (blob 0x%x)' % (arm['image_size'], target,
                                        len(kernel)))
    check('bounds:runtime-inside-image',
          shim_off + runtime_size <= target,
          'runtime end 0x%x, image 0x%x' % (shim_off + runtime_size, target))
    check('bounds:section-table-room',
          new_sec + PE_SECTION_HDR_SIZE <= pe['size_of_headers'],
          'new entry at 0x%x, SizeOfHeaders 0x%x'
          % (new_sec, pe['size_of_headers']))
    # The new section header lands in the header padding, so it must not sit
    # on top of any stock section payload.
    check('bounds:section-gap-unused',
          all(new_sec + PE_SECTION_HDR_SIZE <= sec['raw_pointer']
              or new_sec >= sec['raw_pointer'] + sec['raw_size']
              for sec in pe['sections']),
          'new section header at 0x%x overlaps section data' % new_sec)
    check('bounds:runtime-file-align',
          shim_off % file_align == 0 and runtime_size % file_align == 0,
          'shim_off=0x%x size=0x%x file_align=0x%x'
          % (shim_off, runtime_size, file_align))
    out = bytearray(kernel)
    struct.pack_into('<Q', out, ARM64_HDR_IMAGE_SIZE, target)
    struct.pack_into('<H', out, sig_off + PE_NUM_SECTIONS_OFF, nsec + 1)
    struct.pack_into('<I', out, opt + PE_SIZE_OF_IMAGE_OFF, target)
    struct.pack_into('<8sIIIIIIHHI', out, new_sec, RUNTIME_SECTION_NAME,
                     runtime_size, shim_off, runtime_size, shim_off,
                     0, 0, 0, 0, PE_SEC_CHARS_RUN)
    words = {ARM64_HDR_IMAGE_SIZE & ~3, (sig_off + PE_NUM_SECTIONS_OFF) & ~3,
             (opt + PE_SIZE_OF_IMAGE_OFF) & ~3}
    for off in range(new_sec, new_sec + PE_SECTION_HDR_SIZE, 4):
        words.add(off)
    section = {'name': RUNTIME_SECTION_NAME.decode('latin1'),
               'virtual_size': runtime_size, 'virtual_address': shim_off,
               'raw_size': runtime_size, 'raw_pointer': shim_off}
    bounds = {'image_size': target, 'size_of_image': target,
              'section_count': nsec + 1, 'section_entry_off': new_sec,
              'section': section, 'patch_words': sorted(words)}
    return bytes(out), bounds


# ---------------------------------------------------------------------------
# Gen2 diagnostic: stage-1 probe in the header padding
# ---------------------------------------------------------------------------

STUB_PROBE_WORDS = (
    0x1000000A,  # adr  x10, #0                 x10 = image_base + stub_off
    0xD1000000,  # sub  x10, x10, #stub_off     (immediate set per layout)
    0xD2800000,  # mov  x11, #runtime_off>>16   (immediate set per layout)
    0xD370BD6B,  # lsl  x11, x11, #16
    0x8B0B014C,  # add  x12, x10, x11           x12 = runtime address
    0xB940018D,  # ldr  w13, [x12]              first word actually resident
    0x52800000,  # mov  w14, #magic&0xffff      (immediate set per layout)
    0x72A00000,  # movk w14, #magic>>16, lsl 16
    0x6B0E01BF,  # cmp  w13, w14
    0x54000041,  # b.ne +12 bytes               not the runtime -> spin
    0xD61F0180,  # br   x12                     the payload is resident
    0x14000000,  # b .                          hang on purpose, visible
)


def build_stage1_probe(stub_off, runtime_off, magic_word):
    '''Encode the stage-1 probe: enter the payload only if it is resident.

    A device that spins forever without leaving the boot splash means the
    appended runtime never made it into memory; a device that boots Android
    means it did.  Only x10-x14 are clobbered, so the DTB in x0 and the spare
    arguments in x1-x3 survive for the payload and for the kernel.'''
    check("probe:stub-offset", 0 < stub_off < 0x1000 and stub_off % 4 == 0,
          "0x%x (SUB immediate is 12-bit)" % stub_off)
    check("probe:runtime-offset",
          runtime_off % 0x10000 == 0 and 0 < runtime_off >> 16 < 0x10000,
          "0x%x" % runtime_off)
    check("probe:magic-loadable", (magic_word >> 16) < 0x10000,
          "0x%08x" % magic_word)
    words = list(STUB_PROBE_WORDS)
    words[1] |= (stub_off << 10) | (10 << 5) | 10
    words[2] |= ((runtime_off >> 16) << 5) | 11
    words[6] |= ((magic_word & 0xFFFF) << 5) | 14
    words[7] |= ((magic_word >> 16) << 5) | 14
    return struct.pack("<%dI" % len(words), *words)


def patch_stage1_probe(kernel, entry_off, stub_off, shim_off, magic_word):
    out = bytearray(kernel)
    check("probe:gap-unused",
          all(le32(kernel, off) in (0x00000000, 0xD503201F)
              for off in range(stub_off,
                               stub_off + len(STUB_PROBE_WORDS) * 4, 4)),
          "first used word at 0x%x"
          % first_nonzero(kernel, stub_off,
                          stub_off + 4 * len(STUB_PROBE_WORDS)))
    struct.pack_into("<I", out, entry_off, encode_bl(entry_off, stub_off))
    stub = build_stage1_probe(stub_off, shim_off, magic_word)
    out[stub_off:stub_off + len(stub)] = stub
    words = {entry_off}
    for off in range(stub_off, stub_off + len(stub), 4):
        words.add(off)
    return bytes(out), {"stub_off": stub_off, "stub_bytes": len(stub),
                        "magic_word": "0x%08x" % magic_word,
                        "bl_target": stub_off, "patch_words": sorted(words)}


# ---------------------------------------------------------------------------
# Gen2 code1 entry: no self-modifying base kernel
# ---------------------------------------------------------------------------

def encode_b(from_off, to_off):
    imm = to_off - from_off
    check("b:range", -BL_RANGE < imm < BL_RANGE,
          "distance 0x%x out of B range" % imm)
    imm26 = (imm >> 2) & 0x03FFFFFF
    return 0x14000000 | imm26


def patch_code1(kernel, entry_off, shim_off):
    """Divert the loader at the ARM64 header instead of inside the kernel.

    code1 is the branch the bootloader executes when it enters the image, and
    it runs exactly once - by the loader, before the kernel exists.  Pointing
    it at the runtime hands the shim control with the same register state the
    kernel would have had, while primary_entry keeps every one of its
    original instructions.  Nothing then has to be written back into the base
    kernel at runtime: no self-modifying code, no instruction-cache
    maintenance, and no assumption that the kernel image is mapped writable.
    """
    out = bytearray(kernel)
    code1 = le32(out, ARM64_HDR_CODE1)
    check("code1:is-b", is_branch(code1), "code1=0x%08x" % code1)
    target = decode_b(code1, ARM64_HDR_CODE1)
    check("code1:target-is-entry", target == entry_off,
          "code1 targets 0x%x, expected the entry 0x%x" % (target, entry_off))
    word = encode_b(ARM64_HDR_CODE1, shim_off)
    struct.pack_into("<I", out, ARM64_HDR_CODE1, word)
    return bytes(out), {"code1_word": "0x%08x" % word, "bl_target": shim_off,
                        "original_word": "0x%08x" % code1,
                        "patch_words": [ARM64_HDR_CODE1]}


def patch_runtime_contract(runtime, shim_off, entry_off, manifest_off,
                           manifest_size):
    """Fill in the contract block the Gen2 code1 runtime carries.

    Entered from a branch rather than a call, the runtime cannot recover the
    base image from a link register, and its own link address tells it only
    where it was loaded.  The repacker writes the offsets it knows instead:
    the runtime subtracts shim_offset from its own load address to find the
    base image and reads the manifest from there.
    """
    needle = struct.pack("<II", RUNTIME_CONTRACT_MAGIC,
                         RUNTIME_CONTRACT_VERSION) + b"\x00" * 32
    at = runtime.find(needle)
    check("contract:found", at >= 0,
          "no %d-byte contract block in the runtime" % RUNTIME_CONTRACT_BYTES)
    check("contract:unique", runtime.find(needle, at + 1) < 0,
          "contract block appears more than once")
    check("contract:aligned", at % 8 == 0, "0x%x" % at)
    out = bytearray(runtime)
    struct.pack_into("<QQQQ", out, at + 8, shim_off, entry_off, manifest_off,
                     manifest_size)
    return bytes(out), at


def replay_code1_contract(kernel, runtime_blob, runtime_at, manifest_off,
                          manifest_size, contract_off, entry_off):
    """Replay the runtime code1 self-location on the packed image."""
    magic, version, shim, base_entry, mf_off, mf_size = struct.unpack_from(
        "<IIQQQQ", runtime_blob, contract_off)
    check("replay:contract-magic", magic == RUNTIME_CONTRACT_MAGIC,
          "0x%08x" % magic)
    check("replay:contract-version", version == RUNTIME_CONTRACT_VERSION,
          "%d" % version)
    check("replay:contract-shim", shim == runtime_at,
          "0x%x expected 0x%x" % (shim, runtime_at))
    check("replay:contract-entry", base_entry == entry_off,
          "0x%x expected 0x%x" % (base_entry, entry_off))
    check("replay:contract-manifest",
          mf_off == manifest_off and mf_size == manifest_size,
          "off=0x%x size=0x%x expected off=0x%x size=0x%x"
          % (mf_off, mf_size, manifest_off, manifest_size))
    # The runtime computes image_base = own_load_address - shim_offset, then
    # entry = image_base + base_entry_offset and manifest = image_base +
    # manifest_offset, so both have to land inside the packed image.
    image_base = runtime_at - shim
    check("replay:contract-image-base", image_base == 0, "0x%x" % image_base)
    check("replay:contract-entry-in-image",
          0 < image_base + base_entry < len(kernel),
          "0x%x" % (image_base + base_entry))
    check("replay:contract-manifest-in-image",
          image_base + mf_off + mf_size <= len(kernel),
          "0x%x+0x%x vs image 0x%x" % (image_base + mf_off, mf_size,
                                       len(kernel)))
    magic, vmaj, vmin = struct.unpack_from("<IHH", kernel, image_base + mf_off)
    check("replay:contract-manifest-header",
          magic == MANIFEST_MAGIC and (vmaj, vmin) == MANIFEST_VERSION,
          "magic=0x%08x version=%r" % (magic, (vmaj, vmin)))


# ---------------------------------------------------------------------------
# Packing
# ---------------------------------------------------------------------------

def pack(stock_boot, runtime, base_name, shim_name, stage1_probe=False,
         entry_code1=False):
    hdr = parse_boot_header(stock_boot)
    check("pack:magic", hdr["magic"] == MAGIC, repr(hdr["magic"]))
    check("pack:version", hdr["version"] == 4, "version=%d" % hdr["version"])
    check("pack:header_size", hdr["header_size"] == HDR_SIZE_EXPECTED,
          "0x%x" % hdr["header_size"])
    ksize = hdr["kernel_size"]
    check("pack:kernel-bounds", 0 < ksize and HDR + ksize <= len(stock_boot),
          "kernel_size=0x%x len=0x%x" % (ksize, len(stock_boot)))
    stock_kernel = stock_boot[HDR:HDR + ksize]
    pe = parse_pe(stock_kernel)
    arm = parse_arm64_header(stock_kernel)
    entry_off = arm["entry"]
    # The patch site has to be code the bootloader actually executes.  The
    # PE entry RVA is the EFI-stub entry and is dead here, so the ARM64
    # header trampoline target is the only valid site; it must still sit
    # inside a mapped section for the same reason.
    check("pack:entry-not-pe-entry", entry_off != pe["entry_rva"],
          "entry 0x%x equals the PE entry RVA" % entry_off)
    check("pack:entry-mapped",
          any(s["virtual_address"] <= entry_off
              < s["virtual_address"] + max(s["virtual_size"], s["raw_size"])
              for s in pe["sections"]),
          "entry 0x%x is outside every PE section" % entry_off)
    check("pack:shim-bl-range",
          -BL_RANGE < ksize - entry_off < BL_RANGE,
          "entry 0x%x to shim end 0x%x" % (entry_off, ksize))

    # The runtime has to land where the loader maps it: on a SectionAlignment
    # boundary and inside the grown image_size/SizeOfImage.  Putting it right
    # behind kernel_size placed it past both, so the entry BL branched into an
    # unmapped region and the device fell straight into Qualcomm crashdump.
    shim_off = align_up(max(ksize, arm["image_size"]), pe["section_align"])
    check("pack:shim-gap-bounded",
          ksize <= shim_off < ksize + pe["section_align"],
          "shim_off=0x%x kernel_size=0x%x" % (shim_off, ksize))
    base_entry = {
        "name": base_name, "offset": 0, "size": ksize,
        "type": MF_TYPE_LINUX, "flags": FLAG_BASE | FLAG_EXEC,
        "alignment": 21,
    }
    shim_entry = {
        "name": shim_name, "offset": shim_off - entry_off,
        "size": RUNTIME_SIZE, "type": MF_TYPE_SHIM,
        "flags": FLAG_EXEC, "entry_offset": 0, "alignment": 2,
    }
    # The manifest size depends only on the entry names (the 5 u64 backup
    # slots are a fixed 40 bytes), so it can be measured before the entry
    # site is patched; the real backup values go in on the rebuild.
    manifest_size = len(build_manifest([0] * 5, base_entry, shim_entry))
    size_of_image = align_up(shim_off + RUNTIME_SIZE + manifest_size,
                             pe["section_align"])
    manifest_off = shim_off + RUNTIME_SIZE
    if entry_code1:
        # The loader is diverted at the ARM64 header, so no base kernel
        # instruction is displaced: the manifest backup records code that is
        # never moved and is informative only.
        backup = [le64(stock_kernel, entry_off + off)
                  for off in (0x00, 0x10, 0x20, 0x28, 0x30)]
        patched_kernel, code1 = patch_code1(stock_kernel, entry_off, shim_off)
        layout = {
            "linux_base": entry_off,
            "shim_off": shim_off,
            "manifest_off": manifest_off,
            "packed_size": manifest_off + manifest_size - entry_off,
            "code1": code1,
        }
    else:
        patched_kernel, backup, layout = patch_entry_site(
            stock_kernel, entry_off, shim_off, manifest_size)
    patched_kernel, bounds = patch_loader_bounds(
        patched_kernel, pe, arm, shim_off, RUNTIME_SIZE, manifest_size)
    if entry_code1 and stage1_probe:
        raise StageError("pack", "--entry-code1 and --stage1-probe are mutually exclusive")
    if stage1_probe:
        # The payload is only useful if the loader carried it into memory.
        # Relay the entry BL through a stub that lives in the header padding
        # (inside SizeOfHeaders, which every load model has to map, and where
        # the ARM64 trampoline already executes) and that enters the payload
        # only when its first word is really resident there.
        stub_off = bounds["section_entry_off"] + PE_SECTION_HDR_SIZE
        patched_kernel, probe = patch_stage1_probe(
            patched_kernel, entry_off, stub_off, shim_off, le32(runtime, 0))
        layout["probe"] = probe
    else:
        layout["probe"] = None
    if entry_code1:
        patched_runtime, contract_off = patch_runtime_contract(
            runtime, shim_off, entry_off, manifest_off, manifest_size)
    else:
        patched_runtime, contract_off = runtime, None
    manifest = build_manifest(backup, base_entry, shim_entry)
    check("pack:manifest-size", len(manifest) == manifest_size,
          "0x%x expected 0x%x" % (len(manifest), manifest_size))

    # Zero fill the SectionAlignment gap in front of the runtime, then pad the
    # blob to exactly image_size/SizeOfImage bytes, so kernel_size, the ARM64
    # image_size and the PE SizeOfImage are one and the same number.
    packed = patched_kernel + b"\x00" * (shim_off - len(patched_kernel))
    packed += patched_runtime + manifest
    packed += b"\x00" * (size_of_image - len(packed))
    check("pack:length", len(packed) == size_of_image,
          "len=0x%x size_of_image=0x%x" % (len(packed), size_of_image))
    check("pack:image-size==kernel-size",
          bounds["image_size"] == len(packed) == size_of_image,
          "image_size=0x%x len=0x%x" % (bounds["image_size"], len(packed)))
    check("pack:runtime-mapped",
          bounds["section"]["virtual_address"] == shim_off
          and bounds["section"]["raw_pointer"] == shim_off,
          "section va/raw must both be 0x%x" % shim_off)
    layout["size_of_image"] = size_of_image
    layout["bounds"] = bounds

    # Gen2 keeps a ramdisk section right after the page-aligned kernel
    # section (a debug/generic ramdisk the header still declares).  The
    # loader lays sections out sequentially, so growing kernel_size moves
    # that section: it has to follow the packed blob at its new page-aligned
    # offset.  Dropping it makes the header describe a ramdisk that is not
    # in the image, and the loader then copies garbage - the boot dies long
    # before the entry BL is ever reached.
    footer = parse_avb_footer(stock_boot)
    stock_tail_off = align_up(HDR + ksize, PAGE_ALIGN)
    tail_end = (footer["original_image_size"] if footer is not None
                else align_up(stock_tail_off + hdr["ramdisk_size"], PAGE_ALIGN))
    check("pack:tail-bounds", HDR + ksize <= stock_tail_off
          and tail_end <= stock_tail_off + len(stock_boot)
          and tail_end <= len(stock_boot),
          "stock_tail_off=0x%x tail_end=0x%x len=0x%x"
          % (stock_tail_off, tail_end, len(stock_boot)))
    tail = stock_boot[stock_tail_off:tail_end]
    check("pack:tail-after-vbmeta-zero",
          footer is None
          or first_nonzero(stock_boot, footer["vbmeta_offset"]
                           + footer["vbmeta_size"], len(stock_boot) - 64) == -1,
          "unexpected data between the stock vbmeta and its footer")
    check("pack:ramdisk-magic", hdr["ramdisk_size"] == 0
          or tail[0:4] == RAMDISK_MAGIC_LZ4,
          "tail[0:4]=%r" % (tail[0:4],))

    tail_off = align_up(HDR + len(packed), PAGE_ALIGN)
    # Section offsets the loader derives: kernel follows the header page,
    # the ramdisk follows the (grown) kernel section, page-aligned.
    check("pack:tail-gap", 0 <= tail_off - (HDR + len(packed)) < PAGE_ALIGN,
          "tail_off=0x%x packed_end=0x%x" % (tail_off, HDR + len(packed)))
    check("pack:ramdisk-fits-tail", hdr["ramdisk_size"] <= len(tail),
          "ramdisk_size=0x%x tail=0x%x" % (hdr["ramdisk_size"], len(tail)))

    # Container: copy the stock header, change only the kernel_size field.
    new_hdr = bytearray(stock_boot[0:HDR])
    struct.pack_into("<I", new_hdr, HDR_KERN_SIZE_OFF, len(packed))
    raw = bytes(new_hdr) + packed
    raw += b"\x00" * (tail_off - len(raw))
    raw += tail
    raw += b"\x00" * (align_up(len(raw), PAGE_ALIGN) - len(raw))
    check("pack:raw-size", len(raw) + 4096 <= BOOT_SIZE,
          "raw=0x%x (tail at 0x%x, 0x%x bytes)"
          % (len(raw), tail_off, len(tail)))
    layout["stock_tail_off"] = stock_tail_off
    layout["tail_off"] = tail_off
    layout["tail_size"] = len(tail)
    return raw, footer, {
        "header": dict(hdr),
        "pe": pe,
        "arm64": arm,
        "kernel_size": ksize,
        "layout": layout,
        "backup": backup,
        "manifest": manifest,
        "packed": packed,
        "raw": raw,
        "tail": tail,
        "stock_kernel": stock_kernel,
        "stock_kernel_sha256": sha256_bytes(stock_kernel),
        "packed_sha256": sha256_bytes(packed),
        "runtime_sha256": sha256_bytes(patched_runtime),
        "runtime_patched": patched_runtime,
        "entry_mode": "code1" if entry_code1 else "entry-site",
        "contract_off": contract_off,
    }



# ---------------------------------------------------------------------------
# AVB re-sealing (mirrors the Gen5 repack_boot_v4.py flow)
# ---------------------------------------------------------------------------

def load_avbtool(path):
    import importlib.util
    if not os.path.isfile(path):
        raise StageError("avb", "avbtool not found: %s" % path)
    spec = importlib.util.spec_from_file_location("_avbtool", path)
    if spec is None or spec.loader is None:
        raise StageError("avb", "cannot load avbtool from %s" % path)
    mod = importlib.util.module_from_spec(spec)
    saved = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = saved
    for name in ("Avb", "ImageHandler",
                 "AvbHashDescriptor", "AvbPropertyDescriptor"):
        if not hasattr(mod, name):
            raise StageError("avb", "avbtool missing %s" % name)
    return mod


def parse_avb_source(mod, image_path):
    handler = None
    try:
        handler = mod.ImageHandler(image_path, read_only=True)
        footer, header, descs, _total = mod.Avb()._parse_image(handler)
    except Exception as e:
        raise StageError("avb", "failed to parse AVB metadata: %s" % e)
    finally:
        if handler is not None:
            handler._image.close()
    if footer is None:
        raise StageError("avb", "avbtool found no footer")
    if getattr(header, "flags", None) != 0:
        raise StageError("avb", "original AVB header flags %r" %
                         getattr(header, "flags", None))
    hashes = [d for d in descs if isinstance(d, mod.AvbHashDescriptor)]
    if len(hashes) != 1:
        raise StageError("avb", "expected one hash descriptor, got %d"
                         % len(hashes))
    old_hash = hashes[0]
    if getattr(old_hash, "partition_name", None) != "boot":
        raise StageError("avb", "hash descriptor partition %r" %
                         getattr(old_hash, "partition_name", None))
    old_flags = getattr(old_hash, "flags", 0)
    if old_flags not in (0, 1):
        raise StageError("avb", "descriptor flags %d unsupported" % old_flags)
    if not old_hash.digest:
        raise StageError("avb", "descriptor digest is empty")
    props = []
    for d in descs:
        if isinstance(d, mod.AvbHashDescriptor):
            continue
        if not isinstance(d, mod.AvbPropertyDescriptor):
            raise StageError("avb", "unsupported descriptor %s" %
                             type(d).__name__)
        if b"\x00" in bytes(d.value):
            raise StageError("avb", "property contains a null byte")
        props.append((d.key, bytes(d.value).decode("utf-8")))
    return {
        "hash_algorithm": old_hash.hash_algorithm,
        "salt": bytes(old_hash.salt).hex(),
        "descriptor_flags": old_flags,
        "rollback_index": getattr(header, "rollback_index", 0),
        "rollback_index_location":
            getattr(header, "rollback_index_location", 0),
        "props": props,
    }


def finalize(raw, stock_boot_path, stock_boot, footer, avbtool, out_path,
             partition_size, logs):
    with open(out_path, "xb") as f:
        f.write(raw)
    if footer is None:
        final = open(out_path, "rb").read()
        final += b"\x00" * (partition_size - len(final))
        with open(out_path, "wb") as f:
            f.write(final)
        return parse_avb_footer(final), final

    src = parse_avb_source(load_avbtool(avbtool), stock_boot_path)
    args = [
        "add_hash_footer",
        "--image", out_path,
        "--partition_size", str(partition_size),
        "--partition_name", "boot",
        "--algorithm", "NONE",
        "--hash_algorithm", src["hash_algorithm"],
        "--salt", src["salt"],
        "--rollback_index", str(src["rollback_index"]),
        "--rollback_index_location", str(src["rollback_index_location"]),
    ]
    if src["descriptor_flags"] & 1:
        args.append("--do_not_use_ab")
    for key, value in src["props"]:
        args += ["--prop", "%s:%s" % (key, value)]
    run([sys.executable, "-B", avbtool] + args, "avbtool_add_hash_footer")

    final = read_bytes(out_path, "final")
    check("avb:final-size", len(final) == partition_size,
          "len=0x%x expected=0x%x" % (len(final), partition_size))
    check("avb:raw-prefix", final[:len(raw)] == raw,
          "final prefix differs from raw image")
    expected_ois = align_up(len(raw), 4096)
    fin_footer = parse_avb_footer(final)
    check("avb:ois", fin_footer is not None
          and fin_footer["original_image_size"] == expected_ois,
          "ois=%s expected=0x%x" % (
              fin_footer and fin_footer["original_image_size"], expected_ois))
    check("avb:vbmeta-bounds",
          fin_footer["vbmeta_size"] > 0
          and fin_footer["vbmeta_offset"] >= expected_ois
          and fin_footer["vbmeta_offset"] + fin_footer["vbmeta_size"]
          <= partition_size - 64,
          "vbo=%d vbs=%d" % (fin_footer["vbmeta_offset"],
                             fin_footer["vbmeta_size"]))
    return fin_footer, final


# ---------------------------------------------------------------------------
# Post-pack verification
# ---------------------------------------------------------------------------

def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(0, n, 4096):
        if a[i:i + 4096] != b[i:i + 4096]:
            for j in range(i, min(i + 4096, n)):
                if a[j] != b[j]:
                    return j
            return n
    return -1


def first_nonzero(buf, start, end):
    for i in range(start, end):
        if buf[i] != 0:
            return i
    return -1


def word_diff_offsets(a, b):
    """4-byte offsets where a and b differ (a is the shorter stock view)."""
    diffs = []
    end = (len(a) // 4) * 4
    for off in range(0, end, 4096):
        stop = min(off + 4096, end)
        if a[off:stop] != b[off:stop]:
            for w in range(off, stop, 4):
                if a[w:w + 4] != b[w:w + 4]:
                    diffs.append(w)
    return diffs


def is_executable_type(type_id):
    return type_id in (MF_TYPE_LINUX, 2, MF_TYPE_SHIM)


def entry_protocol(patched_w0, word1, backup_w0):
    """Mirror of the kShimC runtime detection: classic images keep a
    branch at word one (entered at +4); Gen2 images patch the entry
    prologue itself (word zero becomes the BL, the prologue survives in
    the manifest backup) and are entered at +0 after restore."""
    if is_branch(patched_w0) and not is_branch(word1) and \
            not is_branch(backup_w0):
        return "gen2"
    return "legacy"


def replay_get_manifest(kernel, stock_kernel, linux_base, manifest_off,
                        manifest_size, backup):
    """Replay every kShimC get_manifest() check on the packed blob."""
    if manifest_off < linux_base or manifest_size < MANIFEST_HEADER_SIZE:
        check("replay:bounds", False,
              "manifest_off=0x%x manifest_size=0x%x" % (manifest_off,
                                                        manifest_size))
    mf = parse_manifest(kernel, manifest_off)
    check("replay:magic", mf["magic"] == MANIFEST_MAGIC,
          "0x%08x" % mf["magic"])
    check("replay:version", mf["version"] == (0, 1), str(mf["version"]))
    count = mf["count"]
    check("replay:count", 2 <= count <= 50, "%d" % count)
    check("replay:default", mf["default"] < count, "%d" % mf["default"])
    check("replay:entries-fill", mf["end"] - manifest_off == manifest_size,
          "end=0x%x size=0x%x" % (mf["end"] - manifest_off, manifest_size))
    for entry in mf["entries"]:
        for c in entry["name"].encode("utf-8"):
            if c < 0x20 or c == 0x7f or c == 0x3b:
                check("replay:name-chars", False, repr(entry["name"]))

    shim_index = count - 1
    shim = mf["entries"][shim_index]
    attached_shim_offset = le64(kernel, linux_base + 0x30)
    check("replay:shim-not-default", mf["default"] != shim_index)
    check("replay:shim-type", shim["type"] == MF_TYPE_SHIM,
          "%d" % shim["type"])
    check("replay:shim-flags", shim["flags"] == FLAG_EXEC,
          "0x%x" % shim["flags"])
    check("replay:shim-offset-slot", shim["offset"] == attached_shim_offset,
          "entry=0x%x slot=0x%x" % (shim["offset"], attached_shim_offset))
    check("replay:shim-size", shim["size"] != 0)
    check("replay:shim-entry-offset", shim["entry_offset"] == 0,
          "0x%x" % shim["entry_offset"])

    base = mf["entries"][0]
    check("replay:base-type", base["type"] == MF_TYPE_LINUX,
          "%d" % base["type"])
    check("replay:base-flags",
          (base["flags"] & (FLAG_BASE | FLAG_EXEC)) ==
          (FLAG_BASE | FLAG_EXEC) and
          (base["flags"] & ~(FLAG_BASE | FLAG_EXEC | 8)) == 0,
          "0x%x" % base["flags"])
    check("replay:base-offset", base["offset"] == 0, "0x%x" % base["offset"])

    runtime_image_size = le64(kernel, linux_base + 0x10)
    packed_image_end = linux_base + runtime_image_size
    for index, entry in enumerate(mf["entries"]):
        executable = (entry["flags"] & FLAG_EXEC) != 0
        if executable != is_executable_type(entry["type"]):
            check("replay:exec-type", False,
                  "entry %d type=%d flags=0x%x" % (index, entry["type"],
                                                   entry["flags"]))
        allowed = (FLAG_BASE | FLAG_EXEC | 8) if index == 0 \
            else (2 | FLAG_EXEC | 8 | 16)
        if (entry["flags"] & ~allowed) != 0:
            check("replay:allowed-flags", False,
                  "entry %d flags=0x%x" % (index, entry["flags"]))
        if entry["offset"] > manifest_off or \
                entry["size"] > manifest_off - entry["offset"]:
            check("replay:entry-bounds", False,
                  "entry %d off=0x%x size=0x%x" % (index, entry["offset"],
                                                   entry["size"]))
        if not (2 <= entry["alignment"] <= 21):
            check("replay:alignment", False,
                  "entry %d align=%d" % (index, entry["alignment"]))
        if (entry["flags"] & 16) and entry["type"] != MF_TYPE_LINUX:
            check("replay:qc-type", False, "entry %d" % index)
        if executable and (entry["entry_offset"] > entry["size"] or
                           entry["size"] - entry["entry_offset"] < 4 or
                           (entry["entry_offset"] & 3) != 0):
            check("replay:entry-offset", False,
                  "entry %d off=0x%x size=0x%x" % (index,
                                                   entry["entry_offset"],
                                                   entry["size"]))
        if not (entry["flags"] & 8) and entry["dtb_index"] != 0:
            check("replay:dtb-index", False, "entry %d" % index)
        copy_image = (entry["flags"] & 2) != 0
        if not executable and (copy_image or entry["entry_offset"] != 0 or
                               (entry["flags"] & 8) != 0):
            check("replay:non-exec", False, "entry %d" % index)
        if copy_image:
            if not (executable and entry["load_address"] != 0 and
                    (entry["load_address"] & 3) == 0 and
                    entry["copy_size_max"] != 0 and
                    entry["size"] <= entry["copy_size_max"]):
                check("replay:copy", False, "entry %d" % index)
            if entry["load_address"] < packed_image_end and \
                    entry["load_address"] + entry["size"] > linux_base:
                check("replay:copy-overlap", False, "entry %d" % index)
        elif entry["load_address"] != 0 or entry["copy_size_max"] != 0:
            check("replay:load-zero", False, "entry %d" % index)

    check("replay:packed-covers",
          manifest_off + manifest_size <= packed_image_end,
          "manifest end 0x%x packed end 0x%x" % (manifest_off + manifest_size,
                                                 packed_image_end))
    stock_chunks = [le64(stock_kernel, linux_base + off)
                    for off in (0x00, 0x10, 0x20, 0x28, 0x30)]
    check("replay:backup", list(mf["backup"]) == stock_chunks,
          "backup=%r stock=%r" % (list(mf["backup"]), stock_chunks))
    return mf


def verify_packed(final, stock_boot, runtime, info, partition_size):
    set_stage("verify")
    layout = info["layout"]
    linux_base = layout["linux_base"]
    shim_off = layout["shim_off"]
    manifest_off = layout["manifest_off"]
    packed_size = layout["packed_size"]
    packed = info["packed"]
    stock_kernel = info["stock_kernel"]
    manifest = info["manifest"]

    check("verify:final-length", len(final) == partition_size,
          "0x%x" % len(final))
    check("verify:magic", final[0:8] == MAGIC, repr(final[0:8]))
    check("verify:kernel-size", le32(final, HDR_KERN_SIZE_OFF) == len(packed),
          "0x%x expected 0x%x" % (le32(final, HDR_KERN_SIZE_OFF),
                                  len(packed)))
    check("verify:header-size",
          le32(final, HDR_HDR_SIZE_OFF) == HDR_SIZE_EXPECTED,
          "0x%x" % le32(final, HDR_HDR_SIZE_OFF))
    check("verify:version", le32(final, HDR_VERSION_OFF) == 4,
          "0x%x" % le32(final, HDR_VERSION_OFF))

    kernel = final[HDR:HDR + len(packed)]
    check("verify:packed-region", kernel == packed,
          "first diff at 0x%x" % first_diff(kernel, packed))

    check("verify:linux-base", linux_base == info["arm64"]["entry"],
          "0x%x" % linux_base)

    # Slot 0x00 is a u64: the new BL word plus the original word one
    # (restored from the backup, so unchanged there).  The other four
    # slots are new u64s, so nine words change in total.
    expected_diffs = set(info["layout"]["bounds"]["patch_words"])
    if info.get("entry_mode") == "code1":
        expected_diffs |= set(info["layout"]["code1"]["patch_words"])
    else:
        expected_diffs |= {
            linux_base + 0x00,
            linux_base + 0x10, linux_base + 0x14,
            linux_base + 0x20, linux_base + 0x24,
            linux_base + 0x28, linux_base + 0x2C,
            linux_base + 0x30, linux_base + 0x34,
        }
    if layout.get("probe") is not None:
        expected_diffs |= set(layout["probe"]["patch_words"])
    diff_words = set(word_diff_offsets(stock_kernel, kernel))
    check("verify:diff-words", diff_words == expected_diffs,
          "unexpected=%r missing=%r" % (
              [hex(w) for w in sorted(diff_words - expected_diffs)],
              [hex(w) for w in sorted(expected_diffs - diff_words)]))

    if info.get("entry_mode") == "code1":
        code1 = layout["code1"]
        word = le32(kernel, ARM64_HDR_CODE1)
        check("verify:code1-word", word == int(code1["code1_word"], 16),
              "0x%08x expected %s" % (word, code1["code1_word"]))
        redirected = decode_b(word, ARM64_HDR_CODE1)
        check("verify:code1-target", redirected == shim_off,
              "0x%x expected 0x%x" % (redirected, shim_off))
        # The base kernel entry has to be byte identical to stock: that is
        # the entire point of the code1 protocol.
        check("verify:entry-untouched",
              kernel[linux_base:linux_base + 0x40]
              == stock_kernel[linux_base:linux_base + 0x40],
              "first diff at 0x%x"
              % first_diff(kernel[linux_base:linux_base + 0x40],
                           stock_kernel[linux_base:linux_base + 0x40]))
    else:
        bl = le32(kernel, linux_base)
        bl_target = decode_bl(bl, linux_base)
        expected_bl = encode_bl(linux_base, layout.get("probe")
                                and layout["probe"]["bl_target"] or shim_off)
        check("verify:bl-word", bl == expected_bl,
              "0x%08x expected 0x%08x" % (bl, expected_bl))
        check("verify:bl-target", bl_target == (layout.get("probe")
              and layout["probe"]["bl_target"] or shim_off),
              "0x%x" % bl_target)

    probe = layout.get("probe")
    if probe is not None:
        stub = build_stage1_probe(probe["stub_off"], shim_off, le32(runtime, 0))
        check("verify:probe-stub",
              kernel[probe["stub_off"]:probe["stub_off"] + probe["stub_bytes"]]
              == stub,
              "first diff at 0x%x"
              % first_diff(kernel[probe["stub_off"]:
                                  probe["stub_off"] + probe["stub_bytes"]],
                           stub))
        check("verify:probe-inside-headers",
              probe["stub_off"] + probe["stub_bytes"]
              <= info["pe"]["size_of_headers"],
              "stub 0x%x+0x%x vs SizeOfHeaders 0x%x"
              % (probe["stub_off"], probe["stub_bytes"],
                 info["pe"]["size_of_headers"]))
        magic = le32(runtime, 0)
        encoded = (((struct.unpack_from("<I", stub, 7 * 4)[0] >> 5) & 0xFFFF)
                   << 16) | ((struct.unpack_from("<I", stub, 6 * 4)[0] >> 5)
                             & 0xFFFF)
        check("verify:probe-magic", encoded == magic,
              "stub compares against 0x%08x, runtime first word 0x%08x"
              % (encoded, magic))
    if info.get("entry_mode") != "code1":
        check("verify:packed-size-slot", le64(kernel, linux_base + 0x10) ==
              packed_size, "0x%x" % le64(kernel, linux_base + 0x10))
        check("verify:manifest-offset-slot",
              le64(kernel, linux_base + 0x20) == manifest_off - linux_base,
              "0x%x" % le64(kernel, linux_base + 0x20))
        check("verify:manifest-size-slot",
              le64(kernel, linux_base + 0x28) == len(manifest),
              "0x%x" % le64(kernel, linux_base + 0x28))
        check("verify:shim-offset-slot",
              le64(kernel, linux_base + 0x30) == shim_off - linux_base,
              "0x%x" % le64(kernel, linux_base + 0x30))

    runtime_blob = info["runtime_patched"]
    check("verify:runtime-region",
          kernel[shim_off:shim_off + RUNTIME_SIZE] == runtime_blob,
          "first diff at 0x%x" % first_diff(
              kernel[shim_off:shim_off + RUNTIME_SIZE], runtime_blob))
    check("verify:manifest-bytes",
          kernel[manifest_off:manifest_off + len(manifest)] == manifest,
          "first diff at 0x%x" % first_diff(
              kernel[manifest_off:manifest_off + len(manifest)], manifest))
    # Loader-visible bounds have to cover the runtime: kernel_size, the ARM64
    # image_size and the PE SizeOfImage all equal the packed length, and the
    # runtime is declared as a real section with VA == PointerToRawData, so a
    # section-mapping loader and a flat-copying loader agree on one address.
    pe_packed = parse_pe(kernel)
    arm_packed = parse_arm64_header(
        kernel, code1_target=(shim_off if info.get("entry_mode") == "code1"
                               else None))
    check("verify:bounds-unified",
          len(packed) == le32(final, HDR_KERN_SIZE_OFF)
          == arm_packed["image_size"] == pe_packed["size_of_image"],
          "kernel_size=0x%x image_size=0x%x size_of_image=0x%x"
          % (le32(final, HDR_KERN_SIZE_OFF), arm_packed["image_size"],
             pe_packed["size_of_image"]))
    check("verify:sections-grown",
          pe_packed["section_count"] == info["pe"]["section_count"] + 1,
          "%d -> %d" % (info["pe"]["section_count"],
                        pe_packed["section_count"]))
    check("verify:runtime-section",
          any(sec["virtual_address"] == shim_off
              and sec["raw_pointer"] == shim_off
              and sec["raw_size"] == RUNTIME_SIZE
              and sec["virtual_size"] == RUNTIME_SIZE
              for sec in pe_packed["sections"]),
          "; ".join("%s va=0x%x raw=0x%x size=0x%x"
                    % (sec["name"], sec["virtual_address"],
                       sec["raw_pointer"], sec["raw_size"])
                    for sec in pe_packed["sections"]))
    header_kept = (arm_packed["text_offset"] == info["arm64"]["text_offset"]
                   and arm_packed["flags"] == info["arm64"]["flags"]
                   and arm_packed["code0"] == info["arm64"]["code0"]
                   and pe_packed["entry_rva"] == info["pe"]["entry_rva"])
    if info.get("entry_mode") == "code1":
        # code1 is the one header field the code1 protocol redirects, and
        # verify:code1-word plus verify:entry-untouched pin down where it goes.
        header_kept = header_kept and is_branch(arm_packed["code1"])
    else:
        header_kept = (header_kept
                       and arm_packed["code1"] == info["arm64"]["code1"])
    check("verify:header-contract-kept", header_kept,
          "text_offset/flags/code0/PE entry must stay intact")
    check("verify:runtime-gap-zero",
          kernel[info["kernel_size"]:shim_off]
          == b"\x00" * (shim_off - info["kernel_size"]),
          "nonzero bytes in the SectionAlignment gap before the runtime")
    check("verify:runtime-inside-image",
          shim_off + RUNTIME_SIZE <= len(packed),
          "runtime end 0x%x > image 0x%x" % (shim_off + RUNTIME_SIZE,
                                             len(packed)))

    # The stock tail (ramdisk section) must survive, relocated to the
    # page-aligned offset the loader now computes for it.
    tail = info["tail"]
    tail_off = layout["tail_off"]
    check("verify:ramdisk-size-kept",
          le32(final, 0x0C) == le32(stock_boot, 0x0C),
          "0x%x" % le32(final, 0x0C))
    check("verify:ramdisk-load-kept",
          le32(final, 0x10) == le32(stock_boot, 0x10),
          "0x%x" % le32(final, 0x10))
    check("verify:pack-gap-zero",
          final[HDR + len(packed):tail_off]
          == b"\x00" * (tail_off - HDR - len(packed)),
          "nonzero gap before the relocated ramdisk section")
    check("verify:tail-preserved",
          final[tail_off:tail_off + len(tail)] == tail,
          "first diff at 0x%x" % first_diff(
              final[tail_off:tail_off + len(tail)], tail))
    check("verify:tail-room",
          tail_off + len(tail) + 4096 <= partition_size,
          "tail_end=0x%x" % (tail_off + len(tail)))

    if info.get("entry_mode") == "code1":
        replay_code1_contract(kernel, runtime_blob, shim_off, manifest_off,
                              len(manifest), info["contract_off"], linux_base)
    else:
        replay_get_manifest(kernel, stock_kernel, linux_base, manifest_off,
                            len(manifest), info["backup"])

    check("verify:entry-in-payload",
          linux_base + 0x38 <= info["pe"]["last_nonzero"],
          "entry site 0x%x past payload end 0x%x"
          % (linux_base + 0x38, info["pe"]["last_nonzero"]))


# ---------------------------------------------------------------------------
# Offline round-trip
# ---------------------------------------------------------------------------

def round_trip_stock(stock_boot, partition_size):
    """Reassemble the stock image from parsed parts and require byte
    identity.  Verifies that the v4 container model (4 KiB header,
    kernel_size, 4 KiB alignment, untouched tail) matches the physical
    layout of this image, with no runtime and no avbtool required."""
    set_stage("round-trip")
    hdr = parse_boot_header(stock_boot)
    check("rt:magic", hdr["magic"] == MAGIC, repr(hdr["magic"]))
    check("rt:version", hdr["version"] == 4, "%d" % hdr["version"])
    check("rt:header-size", hdr["header_size"] == HDR_SIZE_EXPECTED,
          "0x%x" % hdr["header_size"])
    ksize = hdr["kernel_size"]
    check("rt:kernel-bounds", 0 < ksize and HDR + ksize <= len(stock_boot),
          "0x%x" % ksize)
    kernel = stock_boot[HDR:HDR + ksize]
    pe = parse_pe(kernel)
    arm = parse_arm64_header(kernel)
    orig_w0 = le32(kernel, arm["entry"])
    check("rt:gen2-entry-site", is_bl(orig_w0),
          "original entry word 0x%08x is not a call (not the ARM64 entry "
          "protocol)" % orig_w0)
    check("rt:pe-entry-is-efi-stub", not is_branch(le32(kernel,
          pe["entry_rva"])),
          "PE entry 0x%x is a branch; this image is not an EFI stub build"
          % pe["entry_rva"])
    check("rt:loader-bounds-model",
          0 < arm["image_size"] <= ksize,
          "the runtime goes at align_up(kernel_size, section_align) = 0x%x, "
          "and image_size/SizeOfImage are grown to the packed length"
          % align_up(ksize, pe["section_align"]))
    check("rt:section-table-room",
          pe["sec_off"] + (pe["section_count"] + 1) * PE_SECTION_HDR_SIZE
          <= pe["size_of_headers"],
          "sec_off=0x%x nsec=%d SizeOfHeaders=0x%x"
          % (pe["sec_off"], pe["section_count"], pe["size_of_headers"]))
    entry_protocol_id = "arm64-header-trampoline"
    pad_end = align_up(HDR + ksize, 4096)
    check("rt:pad-bounds", pad_end <= len(stock_boot),
          "0x%x" % pad_end)
    check("rt:pad-zero",
          stock_boot[HDR + ksize:pad_end] ==
          b"\x00" * (pad_end - HDR - ksize),
          "first nonzero at 0x%x" % first_nonzero(
              stock_boot, HDR + ksize, pad_end))
    rt = stock_boot[0:pad_end] + stock_boot[pad_end:]
    if len(rt) < partition_size:
        rt += b"\x00" * (partition_size - len(rt))
    check("rt:identical", rt == stock_boot,
          "first diff at 0x%x" % first_diff(rt, stock_boot))
    footer = parse_avb_footer(stock_boot)
    end = (footer["vbmeta_offset"] if footer is not None
           else len(stock_boot) - 64)
    tail_first = first_nonzero(stock_boot, pad_end, end)
    tail_last = -1
    if tail_first >= 0:
        tail_last = tail_first
        for i in range(end - 1, tail_first - 1, -1):
            if stock_boot[i]:
                tail_last = i
                break
    return {"kernel_size": ksize, "pad_end": pad_end, "pe": pe, "arm64": arm,
            "footer": footer,
            "tail_first_nonzero": tail_first,
            "tail_last_nonzero": tail_last,
            "ramdisk_size": hdr["ramdisk_size"],
            "ramdisk_load": hdr["ramdisk_load"],
            "entry_protocol": entry_protocol_id}



# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def build_report(args, stock_boot, runtime, info, footer, final,
                 round_trip=None):
    layout = info["layout"] if info else {}
    pe = info["pe"] if info else {}
    report = {
        "device": "Lenovo Legion Y700 Gen 2 (TB320FC, SM8475/CapeP)",
        "mode": "round-trip-only" if args.round_trip_only else "pack",
        "inputs": {
            "stock_boot": {
                "path": str(args.stock_boot),
                "sha256": sha256_file(args.stock_boot),
                "bytes": len(stock_boot),
            },
        },
        "caveats": [
            "The entry BL is placed on the ARM64 image-header trampoline "
            "target (code1 branch = primary_entry), not on the PE entry "
            "RVA: this platform boots the stock kernel through the legacy "
            "ARM64 handover (no /sys/firmware/efi on the running Android), "
            "and patching the EFI-stub entry left the shim unreached.",
            "The runtime is appended on a SectionAlignment boundary and the "
            "ARM64 image_size, the PE SizeOfImage and the boot-header "
            "kernel_size are all grown to the same packed length, with the "
            "runtime declared as a real PE section (VA == PointerToRawData). "
            "Appending past image_size/SizeOfImage instead made XBL/ABL fault "
            "the entry BL and reboot into Qualcomm crashdump mode.",
            "The runtime load address is decided by XBL; the shim is "
            "self-locating and the entry BL is relative, so the offset is "
            "load-base independent.",
            "AVB metadata algorithm NONE: the image only verifies on an "
            "unlocked bootloader.",
            "hardware_tested = false",
        ],
        "hardware_tested": False,
    }
    if runtime is not None:
        report["inputs"]["runtime"] = {
            "path": str(args.runtime),
            "sha256": sha256_file(args.runtime),
            "bytes": len(runtime),
        }
    if round_trip is not None:
        report["round_trip"] = {
            "kernel_size": round_trip["kernel_size"],
            "pad_end": round_trip["pad_end"],
            "entry_rva": round_trip["pe"]["entry_rva"],
            "kernel_entry": round_trip["arm64"]["entry"],
            "kernel_entry_word0": "0x%08x" % round_trip["arm64"][
                "entry_word0"],
            "arm64_image_size": round_trip["arm64"]["image_size"],
            "arm64_flags": round_trip["arm64"]["flags"],
            "entry_word0": "0x%08x" % le32(
                stock_boot, HDR + round_trip["pe"]["entry_rva"]),
            "last_nonzero": round_trip["pe"]["last_nonzero"],
            "footer": round_trip["footer"],
            "tail_first_nonzero": round_trip["tail_first_nonzero"],
            "tail_last_nonzero": round_trip["tail_last_nonzero"],
            "ramdisk_size": round_trip["ramdisk_size"],
            "ramdisk_load": round_trip["ramdisk_load"],
            "entry_protocol": round_trip["entry_protocol"],
        }
    if info is not None:
        report["layout"] = {
            "linux_base": layout["linux_base"],
            "shim_off": layout["shim_off"],
            "manifest_off": layout["manifest_off"],
            "packed_size": layout["packed_size"],
            "stage1_probe": layout.get("probe"),
            "size_of_image": layout.get("size_of_image"),
            "runtime_section_entry_off": layout["bounds"]["section_entry_off"],
            "image_size_packed": layout["bounds"]["image_size"],
            "packed_length": len(info["packed"]),
            "raw_length": len(info["raw"]),
            "stock_tail_off": layout["stock_tail_off"],
            "tail_off": layout["tail_off"],
            "tail_size": layout["tail_size"],
            "tail_sha256": sha256_bytes(info["tail"]),
        }
        report["arm64"] = {
            "code0": "0x%08x" % info["arm64"]["code0"],
            "code1": "0x%08x" % info["arm64"]["code1"],
            "entry": info["arm64"]["entry"],
            "entry_word0": "0x%08x" % info["arm64"]["entry_word0"],
            "text_offset": info["arm64"]["text_offset"],
            "image_size": info["arm64"]["image_size"],
            "flags": info["arm64"]["flags"],
            "pe_header_offset": info["arm64"]["pe_header_offset"],
        }
        report["pe"] = {
            "sig_off": pe["sig_off"],
            "machine": pe["machine"],
            "section_count": pe["section_count"],
            "ext_off": pe["ext_off"],
            "ext_len": pe["ext_len"],
            "ext_magic": pe["ext_magic"],
            "image_base": pe["image_base"],
            "entry_rva": pe["entry_rva"],
            "entry_word0": pe["entry_word0"],
            "last_nonzero": pe["last_nonzero"],
            "section_align": pe["section_align"],
            "file_align": pe["file_align"],
            "size_of_image": pe["size_of_image"],
            "size_of_headers": pe["size_of_headers"],
            "sections": pe["sections"],
        }
        report["backup"] = [hex(x) for x in info["backup"]]
        report["avb"] = {
            "stock_footer": footer,
            "final_footer": None if not footer else
            "re-sealed with avbtool (NONE)",
        }
    if args.out:
        report["output"] = {
            "path": str(args.out),
            "sha256": sha256_file(args.out)
            if os.path.exists(args.out) else None,
            "bytes": os.path.getsize(args.out)
            if os.path.exists(args.out) else None,
        }
    report["checks"] = CHECKS
    report["commands"] = COMMANDS
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Pack a kShimC runtime into the Gen2 stock boot image.")
    ap.add_argument("--stock-boot", required=True,
                    help="stock Android boot_a.img (96 MiB)")
    ap.add_argument("--runtime",
                    help="kShimC.bin (4 MiB) from the CrDK build")
    ap.add_argument("--avbtool",
                    help="path to avbtool.py (required when the stock "
                         "image has an AVB footer)")
    ap.add_argument("--out", help="output boot image path")
    ap.add_argument("--report", help="JSON report path (default: out.report.json)")
    ap.add_argument("--partition-size", type=int, default=100663296,
                    help="boot partition size (default 96 MiB)")
    ap.add_argument("--base-name", default=DEFAULT_BASE_NAME)
    ap.add_argument("--shim-name", default=DEFAULT_SHIM_NAME)
    ap.add_argument("--stage1-probe", action="store_true",
                    help="Gen2 diagnostic: relay the entry BL through a stub "
                         "in the header padding that only enters the attached "
                         "runtime when its first word is resident, and spins "
                         "forever otherwise")
    ap.add_argument("--entry-code1", action="store_true",
                    help="Gen2: divert the loader at the ARM64 image header "
                         "branch (code1) instead of patching instructions "
                         "inside the base kernel entry, so the base kernel "
                         "text is never written at runtime")
    ap.add_argument("--round-trip-only", action="store_true",
                    help="validate the stock image model only; no runtime "
                         "or avbtool needed")
    args = ap.parse_args(argv)

    set_stage("init")
    check("init:partition-size", args.partition_size >= BOOT_SIZE // 2,
          "0x%x" % args.partition_size)
    stock_boot = read_bytes(args.stock_boot, "stock")
    check("init:stock-length", len(stock_boot) == args.partition_size,
          "0x%x expected 0x%x" % (len(stock_boot), args.partition_size))

    runtime = None
    if not args.round_trip_only:
        if not args.runtime:
            raise SystemExit("error: --runtime is required unless "
                             "--round-trip-only")
        runtime = read_bytes(args.runtime, "runtime")
        check("init:runtime-size", len(runtime) == RUNTIME_SIZE,
              "0x%x expected 0x%x" % (len(runtime), RUNTIME_SIZE))
        if not args.out:
            raise SystemExit("error: --out is required")

    footer = parse_avb_footer(stock_boot)
    if not args.round_trip_only:
        if footer is not None and not args.avbtool:
            raise SystemExit("error: stock image has an AVB footer; "
                             "--avbtool <path> is required")
        if footer is None and args.avbtool:
            print("note: stock image has no AVB footer; --avbtool ignored")

    round_trip = None
    info = None
    final = None
    if args.round_trip_only:
        round_trip = round_trip_stock(stock_boot, args.partition_size)
    else:
        set_stage("pack")
        raw, footer, info = pack(stock_boot, runtime, args.base_name,
                                 args.shim_name, args.stage1_probe,
                                 args.entry_code1)
        if footer is None:
            check("pack:no-footer-pad", len(raw) <= args.partition_size,
                  "0x%x" % len(raw))
        set_stage("finalize")
        logs = os.path.join(
            os.path.dirname(os.path.abspath(args.out)), "kshim-packer-logs")
        os.makedirs(logs, exist_ok=True)
        final_footer, final = finalize(raw, args.stock_boot, stock_boot,
                                       footer, args.avbtool, args.out,
                                       args.partition_size, logs)
        if final is not None:
            set_stage("verify")
            verify_packed(final, stock_boot, runtime, info,
                          args.partition_size)

    report_path = args.report or (
        (args.out + ".report.json") if args.out
        else os.path.join(os.path.dirname(
            os.path.abspath(args.stock_boot)), "round-trip.report.json"))
    report = build_report(args, stock_boot, runtime, info, footer, final,
                          round_trip)
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False, sort_keys=True)
        f.write("\n")

    failed = [c for c in CHECKS if not c["ok"]]
    print("checks: %d ok, %d failed" % (len(CHECKS) - len(failed), len(failed)))
    print("report: %s" % report_path)
    if not args.round_trip_only and args.out:
        print("output: %s (%d bytes)" % (args.out, os.path.getsize(args.out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
