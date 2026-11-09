#!/bin/bash
# A82 = A81 + the initramfs may hand over to a real distribution root.
#
# The panel shows our console (A81) and touch works at boot (A80), so the next
# step is the install: ArmadaOS lives flattened on UFS sda16 and its init is
# /sbin/init -> systemd, which the A-series root gate used to reject (it wanted
# /init plus a busybox).  A82 generalises try_root(), adds the CARD_FIRST_GO card
# marker so an install round runs from the card root without re-migrating UFS, and
# puts selinux=0 plus systemd.unit=multi-user.target on the forced cmdline, because
# the flattened ext4 copy carries no SELinux labels.  Kernel code is byte-for-byte
# A81; the DTB is byte-for-byte A70/A73.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
echo "=== a82 build start $(date -u) ==="
echo "A82 = A81 + a distro-capable root gate (switch_root into systemd) and selinux=0:"
echo "try_root() only ever accepted our own Alpine root.  It now accepts /init, /sbin/init or"
echo "/usr/lib/systemd/systemd, skips the busybox probe when a root has no busybox, and the new"
echo "CARD_FIRST_GO card marker asks for the card root without asking the card /init for a migration."
ls -l "$B/armada-boot/vmlinuz" || exit 1
sha256sum "$B/armada-boot/vmlinuz" || exit 1
[ -s "$B/out/boot-b-a70.img" ] || { echo NO_A70_REF; exit 1; }
[ -s "$B/chk_a73.dts" ] || { echo NO_A73_DTS; exit 1; }
grep -q 'CONFIG_SPI_QCOM_GENI=y' .config || { echo NO_SPI_GENI_CFG; exit 1; }
grep -q 'CONFIG_DRM_PANEL_Y700_STUB=y' .config || { echo NO_STUB_CFG; exit 1; }

python3 /tmp/y700/kbuild/patch_a73.py || { echo PATCH_A73_FAIL; exit 1; }
scripts/config --enable FRAMEBUFFER_CONSOLE || { echo A82_CONFIG_TOOL_FAIL; exit 1; }
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/y700/kbuild/a82-olddefconfig.log 2>&1 || { echo A82_OLDDEFCONFIG_FAIL; exit 1; }
python3 /tmp/y700/kbuild/patch_a82.py || { echo PATCH_A82_FAIL; exit 1; }
bash -n /tmp/y700/initramfs/init || { echo A82_INIT_BASH_SYNTAX; exit 1; }
if command -v busybox >/dev/null ; then busybox sh -n /tmp/y700/initramfs/init || { echo A82_INIT_BB_SYNTAX; exit 1; } ; else echo A82_NO_BUSYBOX_ON_BUILDER; fi
grep -q 'A82 SWITCH_ROOT_TO' /tmp/y700/initramfs/init || { echo A82_INIT_PATCH_MISSING; exit 1; }
grep -q 'CARD_FIRST_GO\*) RESYNC=1' /tmp/y700/initramfs/init || { echo A82_MARKER_MISSING; exit 1; }
grep -q '/usr/lib/systemd/systemd ; do' /tmp/y700/initramfs/init || { echo A82_INIT_GATE_MISSING; exit 1; }
grep -q 'CONFIG_FRAMEBUFFER_CONSOLE=y' .config || { echo A82_FBCON_MISSING; exit 1; }
grep -q 'static bool y700fb_takeover = true;' drivers/video/fbdev/y700fb.c || { echo A82_TAKEOVER_NOT_DEFAULT; exit 1; }
grep -q 'static bool force_pio = true;' drivers/spi/spi-geni-qcom.c || { echo PIO_NOT_DEFAULT; exit 1; }
grep -q 'y700fb_takeover' drivers/video/fbdev/y700fb.c || { echo FB_PARAM_MISSING; exit 1; }
grep -q 'module_param(nvt_stage, int, 0644)' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo TOUCH_PARAM_MISSING; exit 1; }
grep -q 'module_param(force_pio, bool, 0644)' drivers/spi/spi-geni-qcom.c || { echo PIO_PARAM_MISSING; exit 1; }
grep -q 'module_param(nvt_fw_chunk, int, 0644)' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo CHUNK_PARAM_MISSING; exit 1; }
grep -q 'static int nvt_fw_chunk = 16384;' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo A82_CHUNK_DEFAULT_NOT_16K; exit 1; }
grep -q 'module_param(nvt_fw_bytes, int, 0644)' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo LIMIT_PARAM_MISSING; exit 1; }
grep -q 'if (force_pio)' drivers/spi/spi-geni-qcom.c || { echo PIO_NOT_WIRED; exit 1; }
OLD_CMDLINE='initcall_blacklist=clk_disable_unused,genpd_power_off_unused,regulator_init_complete"'
NEW_CMDLINE='initcall_blacklist=clk_disable_unused,genpd_power_off_unused,regulator_init_complete selinux=0 systemd.unit=multi-user.target"'
sed -i "s|$OLD_CMDLINE|$NEW_CMDLINE|" .config || { echo A82_CMDLINE_SED_FAIL; exit 1; }
grep -q 'selinux=0 systemd.unit=multi-user.target"' .config || { echo A82_CMDLINE_MISSING; exit 1; }
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig >> /tmp/y700/kbuild/a82-olddefconfig.log 2>&1 || { echo A82_OLDDEFCONFIG2_FAIL; exit 1; }
grep -q 'CONFIG_CMDLINE_FORCE=y' .config || { echo A82_CMDLINE_FORCE_LOST; exit 1; }

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
nm vmlinux > "$B/nm-a82.txt" || { echo NM_FAIL; exit 1; }
grep -E ' y700_reg_write$| y700_con_write$| simplefb_console_on$' "$B/nm-a82.txt" || { echo SYM_FAIL; exit 1; }
grep -E ' t y700_stub_probe$| t qcom_spi_probe$| t nvt_nt36523n_probe$' "$B/nm-a82.txt" || { echo A70_SYM_FAIL; exit 1; }
grep -E ' [bB] force_pio$| [bB] nvt_fw_chunk$| [bB] nvt_fw_bytes$| [bB] nvt_stage$' "$B/nm-a82.txt" || { echo A82_SYM_FAIL; exit 1; }
strings vmlinux | grep -c 'NVT-STAGE 1 reset line released' || { echo STAGE1_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'NVT-FW begin chunk=' || { echo FWBEGIN_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'Y700-GENI xfer' || { echo GENI_MODE_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'console kept on the simplefb earlycon' || { echo FB_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'armada,y700-stub-panel' || { echo STUBMATCH_FAIL; exit 1; }
strings vmlinux | grep -c 'novatek,nt36523n-spi' || { echo TOUCHMATCH_FAIL; exit 1; }
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
grep -c "CARD_FIRST_GO" usr/initramfs_data.cpio || { echo A82_NEW_INIT_NOT_IN_CPIO; exit 1; }
strings vmlinux | grep -c "selinux=0" || { echo A82_CMDLINE_NOT_IN_IMAGE; exit 1; }

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
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a82.dts" || { echo DTC_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a82.dts" || { echo CHK_FAIL; exit 1; }
diff "$B/chk_a73.dts" "$B/chk_a82.dts" > "$B/a82-dtb.diff" || { echo A82_DTB_DIFFERS; cat "$B/a82-dtb.diff"; exit 1; }
echo A82_DTB_SAME_AS_A73
awk '/spi@990000/,/^\t\t\t};/' "$B/chk_a82.dts" | grep -c 'dmas = <' || { echo A82_NO_DMAS_UNEXPECTED; exit 1; }

python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a82.img" || { echo PACK_FAIL; exit 1; }
cp -f "$B/out/boot-b-a82.img" /tmp/y700/e15/ || exit 1
ls -l /tmp/y700/e15/boot-b-a82.img
sha256sum /tmp/y700/e15/boot-b-a82.img /tmp/y700/e15/boot-b-a73.img
echo "=== a82 end $(date -u) ==="
echo A82_ALL_OK
