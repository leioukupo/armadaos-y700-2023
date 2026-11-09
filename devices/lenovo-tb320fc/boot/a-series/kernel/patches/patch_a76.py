#!/usr/bin/env python3
# A76 changes no kernel source: the fix is data, not code.  A75 showed the
# built-in touch driver probes during initcalls, while the root is still the
# embedded initramfs, so request_firmware() cannot see the blob in /lib/firmware
# on the UFS rootfs.  A76 stages the 192 KiB blob inside INITRAMFS_SOURCE, the
# only filesystem that exists that early.  This script only checks preconditions.
import os, sys
K = "/tmp/y700/kbuild/asphalt-linux"
FW = "/tmp/y700/initramfs/lib/firmware/novatek/lenovo-tb320fc.bin"
def read(p):
    with open(os.path.join(K, p), encoding="utf-8") as f:
        return f.read()
spi = read("drivers/spi/spi-geni-qcom.c")
nvt = read("drivers/input/touchscreen/novatek-nt36523n-spi.c")
checks = [
    ("force_pio defaults to PIO", "static bool force_pio = true;" in spi),
    ("force_pio is a 0644 param", "module_param(force_pio, bool, 0644);" in spi),
    ("force_pio consulted in transfer path", "if (force_pio)" in spi),
    ("driver reads DT firmware-name", 'device_property_read_string(dev, "firmware-name"' in nvt),
    ("driver uses request_firmware", "request_firmware(&fw, nvt->firmware_name, dev)" in nvt),
    ("nvt_stage knob", "module_param(nvt_stage, int, 0644);" in nvt),
    ("nvt_fw_chunk knob", "module_param(nvt_fw_chunk, int, 0644);" in nvt),
    ("nvt_fw_bytes knob", "module_param(nvt_fw_bytes, int, 0644);" in nvt),
]
missing = [n for n, ok in checks if not ok]
if missing:
    print("A76_PRECOND_MISSING: " + ", ".join(missing)); sys.exit(1)
if not os.path.isfile(FW) or os.path.getsize(FW) != 196608:
    print("A76_FIRMWARE_NOT_STAGED %s" % FW); sys.exit(1)
cfg = read(".config")
if 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' not in cfg:
    print("A76_INITRAMFS_SOURCE_MOVED"); sys.exit(1)
if "CONFIG_FW_LOADER_USER_HELPER=y" in cfg:
    print("A76_USER_HELPER_UNEXPECTED"); sys.exit(1)
print("A76_PATCH_NOOP_OK firmware=%d bytes staged in the initramfs, kernel source unchanged" % os.path.getsize(FW))
