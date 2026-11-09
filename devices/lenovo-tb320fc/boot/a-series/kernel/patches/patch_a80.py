#!/usr/bin/env python3
# A80 = A76 + a 16 KiB default for nvt_fw_chunk.
#
# A78/A79 pinned the boot-time failure to the host side: spi/core.c
# spi_transfer_wait() budgets 2*(8000*len/spi-max-frequency)+200 ms, i.e. it
# trusts the 9.6 MHz wire rate, while force_pio moves ~250 KB/s through the
# 64-byte SE FIFO.  The vendor 63 KiB chunk (64513 B on the wire) gets 307 ms
# and needs ~310 ms, so the download is a coin toss - A77 got lucky, A76/A78/A79
# hit "SPI transfer timed out -> firmware SRAM transfer failed" and probe
# aborted without an input device.  Writing 16 KiB at a time gives a 227 ms
# budget against ~65 ms of PIO, and A79 proved the whole chain then completes:
# two CRC snapshots matching, firmware 0x1d running, input3 registered.
import sys

P = "drivers/input/touchscreen/novatek-nt36523n-spi.c"
OLD = "static int nvt_fw_chunk;\n"
NEW = ("/* 16 KiB per SPI write, not the vendor 63 KiB: spi_transfer_wait() budgets the\n"
       " * wait from spi-max-frequency (9.6 MHz) but force_pio only moves ~250 KB/s\n"
       " * through the 64-byte QUP SE FIFO, so a 63 KiB chunk loses that race roughly\n"
       " * half the time and the firmware download dies with -ETIMEDOUT. */\n"
       "static int nvt_fw_chunk = 16384;\n")

with open(P, encoding="utf-8") as handle:
    src = handle.read()

if "static int nvt_fw_chunk = 16384;" in src:
    print("A80_PATCH_ALREADY_APPLIED")
elif OLD in src:
    src = src.replace(OLD, NEW, 1)
    with open(P, "w", encoding="utf-8") as handle:
        handle.write(src)
    print("A80_PATCH_APPLIED chunk-default=16384")
else:
    print("A80_PATCH_ANCHOR_MISSING")
    sys.exit(1)

with open(P, encoding="utf-8") as handle:
    src = handle.read()
for marker in ("static int nvt_fw_chunk = 16384;",
               "module_param(nvt_fw_chunk, int, 0644);",
               "static bool force_pio = true;"):
    if marker not in src and marker not in open("drivers/spi/spi-geni-qcom.c", encoding="utf-8").read():
        print("A80_POSTCOND_MISSING " + marker)
        sys.exit(1)
print("A80_PATCH_OK")
