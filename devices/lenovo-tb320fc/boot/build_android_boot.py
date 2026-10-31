#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline TB320FC (Lenovo Legion Y700 Gen 2, SM8475/CapeP) boot packager.

The Gen2 stock boot image is a raw, unsigned-style v4 "ANDROID!" container
(96 MiB) whose kernel blob is a Qualcomm MZ/PE-style wrapper around a flat
ARM64 image:

  * container header: magic @0x00, kernel_size @0x08, debug-ramdisk
    size @0x0C / load address @0x10, header_size @0x14 (1584), version
    @0x28 (4); there is no cmdline field in this variant.
  * the kernel blob starts at 0x1000 with a 64-byte MZ stub (e_lfanew =
    0x40), a 20-byte COFF header (sizeofopt is a decoy zero) and a custom
    160-byte extended header whose entry RVA sits at offset 0x14; the
    trailing section table is a decoy.  The image is flat - file offset
    equals virtual offset - and the loader jumps to the entry RVA (a
    normal function prologue, not a branch).
  * after the 4 KiB-aligned kernel slot the stock image keeps a
    debug-ramdisk payload (header 0x0C/0x10) and, at the end, an AVB
    footer (algorithm NONE) with its vbmeta.  The repack grows the
    kernel slot over the debug-ramdisk region, so that payload is
    dropped in the emitted image (header fields stay untouched); the
    new vbmeta is placed by avbtool at the new original_image_size.

The kShimC handoff therefore patches the entry site itself instead of
offset 0 of the blob:

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
PE_MACHINE_ARM64 = 0xAA64
PE32PLUS_MAGIC = 0x20B
RUNTIME_SIZE = 4 * 1024 * 1024
MANIFEST_MAGIC = 0x464D504B
MANIFEST_VERSION = (0, 1)
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


def patch_entry_site(kernel, entry_rva, shim_off, manifest_size):
    """Return (patched_kernel, backup, layout) for the Gen2 protocol."""
    linux_base = entry_rva
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


# ---------------------------------------------------------------------------
# Packing
# ---------------------------------------------------------------------------

def pack(stock_boot, runtime, base_name, shim_name):
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
    entry_rva = pe["entry_rva"]
    check("pack:shim-bl-range",
          -BL_RANGE < ksize - entry_rva < BL_RANGE,
          "entry 0x%x to shim end 0x%x" % (entry_rva, ksize))

    shim_off = ksize
    base_entry = {
        "name": base_name, "offset": 0, "size": ksize,
        "type": MF_TYPE_LINUX, "flags": FLAG_BASE | FLAG_EXEC,
        "alignment": 21,
    }
    shim_entry = {
        "name": shim_name, "offset": shim_off - entry_rva,
        "size": RUNTIME_SIZE, "type": MF_TYPE_SHIM,
        "flags": FLAG_EXEC, "entry_offset": 0, "alignment": 2,
    }
    # The manifest size depends only on the entry names (the 5 u64 backup
    # slots are a fixed 40 bytes), so it can be measured before the entry
    # site is patched; the real backup values go in on the rebuild.
    manifest_size = len(build_manifest([0] * 5, base_entry, shim_entry))
    patched_kernel, backup, layout = patch_entry_site(
        stock_kernel, entry_rva, shim_off, manifest_size)
    manifest = build_manifest(backup, base_entry, shim_entry)
    check("pack:manifest-size", len(manifest) == manifest_size,
          "0x%x expected 0x%x" % (len(manifest), manifest_size))

    packed = patched_kernel + runtime + manifest
    check("pack:length", len(packed) ==
          layout["manifest_off"] + len(manifest), "len=%d" % len(packed))

    # Container: copy the stock header, change only the kernel_size field.
    new_hdr = bytearray(stock_boot[0:HDR])
    struct.pack_into("<I", new_hdr, HDR_KERN_SIZE_OFF, len(packed))
    raw = bytes(new_hdr) + packed

    # Pad to 4 KiB, then re-seal the AVB footer when the stock image had one.
    raw = raw + b"\x00" * (align_up(len(raw), 4096) - len(raw))
    footer = parse_avb_footer(stock_boot)
    return raw, footer, {
        "header": dict(hdr),
        "pe": pe,
        "kernel_size": ksize,
        "layout": layout,
        "backup": backup,
        "manifest": manifest,
        "packed": packed,
        "raw": raw,
        "stock_kernel": stock_kernel,
        "stock_kernel_sha256": sha256_bytes(stock_kernel),
        "packed_sha256": sha256_bytes(packed),
        "runtime_sha256": sha256_bytes(runtime),
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

    check("verify:linux-base", linux_base == info["pe"]["entry_rva"],
          "0x%x" % linux_base)

    # Slot 0x00 is a u64: the new BL word plus the original word one
    # (restored from the backup, so unchanged there).  The other four
    # slots are new u64s, so nine words change in total.
    expected_diffs = {
        linux_base + 0x00,
        linux_base + 0x10, linux_base + 0x14,
        linux_base + 0x20, linux_base + 0x24,
        linux_base + 0x28, linux_base + 0x2C,
        linux_base + 0x30, linux_base + 0x34,
    }
    diff_words = set(word_diff_offsets(stock_kernel, kernel))
    check("verify:diff-words", diff_words == expected_diffs,
          "unexpected=%r missing=%r" % (
              [hex(w) for w in sorted(diff_words - expected_diffs)],
              [hex(w) for w in sorted(expected_diffs - diff_words)]))

    bl = le32(kernel, linux_base)
    check("verify:bl-word", bl == encode_bl(linux_base, shim_off),
          "0x%08x expected 0x%08x" % (bl, encode_bl(linux_base, shim_off)))
    check("verify:bl-target", decode_bl(bl, linux_base) == shim_off,
          "0x%x" % decode_bl(bl, linux_base))
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

    check("verify:runtime-region",
          kernel[shim_off:shim_off + RUNTIME_SIZE] == runtime,
          "first diff at 0x%x" % first_diff(
              kernel[shim_off:shim_off + RUNTIME_SIZE], runtime))
    check("verify:manifest-bytes",
          kernel[manifest_off:manifest_off + len(manifest)] == manifest,
          "first diff at 0x%x" % first_diff(
              kernel[manifest_off:manifest_off + len(manifest)], manifest))
    check("verify:tail-zero",
          kernel[len(packed):] == b"\x00" * (len(kernel) - len(packed)),
          "nonzero tail after manifest")

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
    orig_w0 = le32(kernel, pe["entry_rva"])
    check("rt:gen2-entry-site", not is_branch(orig_w0),
          "original entry word 0x%08x is a branch (not the Gen2 protocol)"
          % orig_w0)
    entry_protocol_id = "gen2" if not is_branch(orig_w0) else "legacy"
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
    return {"kernel_size": ksize, "pad_end": pad_end, "pe": pe,
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
            "XBL must flat-copy the whole kernel region (the PE section "
            "table is a decoy); inferred from the stock image, unverified "
            "on hardware.",
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
            "packed_length": len(info["packed"]),
            "raw_length": len(info["raw"]),
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
                                 args.shim_name)
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
