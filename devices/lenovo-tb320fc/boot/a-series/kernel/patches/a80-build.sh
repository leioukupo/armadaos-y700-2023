#!/bin/bash
# A80 = A73 + one question answered: is the SE DMA path what resets the board?
#
# A73 walked the touch bring-up stages and the board died in stage 3, right at
# the first host->SRAM firmware write, with nothing on the panel after it.  The
# only thing stage 3 does that stages 1 and 2 do not is a SPI transfer larger
# than the QUP FIFO (NVT_FW_TRANSFER_MAX = 63 KiB), and geni_can_dma() answers
# yes for those, which makes transfer_one() pick GENI_SE_DMA.  A80 adds a
# force_pio parameter to spi-geni-qcom so the very same kernel can drive that
# transfer with PIO, plus chunk/limit knobs in the novatek driver so a download
# can be cut up or stopped part-way.  DTB is byte-for-byte A70/A73.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
echo "=== a80 build start $(date -u) ==="
echo "A80 = A76 (firmware inside the embedded initramfs) + a 16 KiB default chunk:"
echo "A79 proved the boot-time download dies on the host: the spi core budgets transfer"
echo "time from spi-max-frequency while force_pio only moves ~250 KB/s, so the vendor"
echo "63 KiB chunk loses the spi_transfer_wait() race.  16 KiB chunks win it."
ls -l "$B/armada-boot/vmlinuz" || exit 1
sha256sum "$B/armada-boot/vmlinuz" || exit 1
[ -s "$B/out/boot-b-a70.img" ] || { echo NO_A70_REF; exit 1; }
[ -s "$B/chk_a73.dts" ] || { echo NO_A73_DTS; exit 1; }
grep -q 'CONFIG_SPI_QCOM_GENI=y' .config || { echo NO_SPI_GENI_CFG; exit 1; }
grep -q 'CONFIG_DRM_PANEL_Y700_STUB=y' .config || { echo NO_STUB_CFG; exit 1; }
grep -q 'CONFIG_FRAMEBUFFER_CONSOLE is not set' .config || { echo FBCON_NOT_AS_EXPECTED; exit 1; }

python3 /tmp/y700/kbuild/patch_a73.py || { echo PATCH_A73_FAIL; exit 1; }
python3 /tmp/y700/kbuild/patch_a80.py || { echo PATCH_A80_FAIL; exit 1; }
grep -q 'static bool force_pio = true;' drivers/spi/spi-geni-qcom.c || { echo PIO_NOT_DEFAULT; exit 1; }
grep -q 'y700fb_takeover' drivers/video/fbdev/y700fb.c || { echo FB_PARAM_MISSING; exit 1; }
grep -q 'module_param(nvt_stage, int, 0644)' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo TOUCH_PARAM_MISSING; exit 1; }
grep -q 'module_param(force_pio, bool, 0644)' drivers/spi/spi-geni-qcom.c || { echo PIO_PARAM_MISSING; exit 1; }
grep -q 'module_param(nvt_fw_chunk, int, 0644)' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo CHUNK_PARAM_MISSING; exit 1; }
grep -q 'static int nvt_fw_chunk = 16384;' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo A80_CHUNK_DEFAULT_NOT_16K; exit 1; }
grep -q 'module_param(nvt_fw_bytes, int, 0644)' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo LIMIT_PARAM_MISSING; exit 1; }
grep -q 'if (force_pio)' drivers/spi/spi-geni-qcom.c || { echo PIO_NOT_WIRED; exit 1; }

FW=/tmp/y700/initramfs/lib/firmware/novatek/lenovo-tb320fc.bin
[ -s "$FW" ] || { echo NO_FW_IN_INITRAMFS; exit 1; }
[ "$(wc -c < "$FW")" = "196608" ] || { echo FW_WRONG_SIZE; exit 1; }
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }
# the kernel does not notice new files inside INITRAMFS_SOURCE, so drop the cpio
# and its object and let the build regenerate them.
rm -f usr/initramfs_data.cpio usr/initramfs_data.o
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image || { echo MAKE_FAIL; exit 1; }
cpio_name=$(grep -c 'lenovo-tb320fc.bin' usr/initramfs_data.cpio)
[ "$cpio_name" -ge 1 ] || { echo FW_NOT_IN_CPIO; exit 1; }
grep -c 'lenovo-tb320fc.bin' usr/initramfs_data.cpio
ls -l usr/initramfs_data.cpio
nm vmlinux > "$B/nm-a80.txt" || { echo NM_FAIL; exit 1; }
grep -E ' y700_reg_write$| y700_con_write$| simplefb_console_on$' "$B/nm-a80.txt" || { echo SYM_FAIL; exit 1; }
grep -E ' t y700_stub_probe$| t qcom_spi_probe$| t nvt_nt36523n_probe$' "$B/nm-a80.txt" || { echo A70_SYM_FAIL; exit 1; }
grep -E ' [bB] force_pio$| [bB] nvt_fw_chunk$| [bB] nvt_fw_bytes$| [bB] nvt_stage$' "$B/nm-a80.txt" || { echo A80_SYM_FAIL; exit 1; }
strings vmlinux | grep -c 'NVT-STAGE 1 reset line released' || { echo STAGE1_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'NVT-FW begin chunk=' || { echo FWBEGIN_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'Y700-GENI xfer' || { echo GENI_MODE_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'console kept on the simplefb earlycon' || { echo FB_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'armada,y700-stub-panel' || { echo STUBMATCH_FAIL; exit 1; }
strings vmlinux | grep -c 'novatek,nt36523n-spi' || { echo TOUCHMATCH_FAIL; exit 1; }
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1

# DTB exactly as A70/A73 left it
export Y700_EXTRA_DISABLE='display-subsystem@ae00000,display-controller@ae01000,displayport-controller@ae90000,dsi@ae94000,dsi@ae96000,phy@ae94400,phy@ae96400,clock-controller@af00000'
unset Y700_A65_BL_OFF
export Y700_A70=1

dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; printf '%s\n' "$dtbout"; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A65 pin skipped' || { echo A65_GUARD_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A70: y700-stub-panel added' || { echo A70_STEP_MISSING; exit 1; }
cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a80.dts" || { echo DTC_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a80.dts" || { echo CHK_FAIL; exit 1; }
diff "$B/chk_a73.dts" "$B/chk_a80.dts" > "$B/a80-dtb.diff" || { echo A80_DTB_DIFFERS; cat "$B/a80-dtb.diff"; exit 1; }
echo A80_DTB_SAME_AS_A73
awk '/spi@990000/,/^\t\t\t};/' "$B/chk_a80.dts" | grep -c 'dmas = <' || { echo A80_NO_DMAS_UNEXPECTED; exit 1; }

python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a80.img" || { echo PACK_FAIL; exit 1; }
cp -f "$B/out/boot-b-a80.img" /tmp/y700/e15/ || exit 1
ls -l /tmp/y700/e15/boot-b-a80.img
sha256sum /tmp/y700/e15/boot-b-a80.img /tmp/y700/e15/boot-b-a73.img
echo "=== a80 end $(date -u) ==="
echo A80_ALL_OK
