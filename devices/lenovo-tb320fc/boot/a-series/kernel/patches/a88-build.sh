#!/bin/bash
# A88 = A82 + the ABL splash memory exposed as a real KMS device (simpledrm).
#
# Nothing about the boot order, the DTB, the cmdline or the initramfs changes:
# one config option (CONFIG_DRM_SIMPLEDRM) plus the y700fb handover, so the panel
# keeps exactly the pixels it has today and gains /dev/dri/card0 on top of them.
# That is the difference between "we can print on the glass" and "weston, cage and
# Xwayland can run" - none of them have an fbdev backend any more.
set -x
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
cd "$K" || exit 1
echo "=== a88 build start $(date -u) ==="
echo "A88 = A82 + simpledrm over the /chosen simple-framebuffer, y700fb stands down:"
echo "the board DTB node is already a valid simple-framebuffer (1600x2560 a8r8g8b8 stride 6400)"
echo "and the kernel creates a platform device for it at arch_initcall_sync, so the driver"
echo "only has to be built in.  y700fb then skips its own fb and only stops the earlycon."
ls -l "$B/armada-boot/vmlinuz" || exit 1
[ -s "$B/out/boot-b-a70.img" ] || { echo NO_A70_REF; exit 1; }
[ -s "$B/chk_a73.dts" ] || { echo NO_A73_DTS; exit 1; }
grep -q 'CONFIG_FB_Y700=y' .config || { echo NO_FB_Y700_CFG; exit 1; }
grep -q 'CONFIG_DRM_FBDEV_EMULATION=y' .config || { echo NO_FBDEV_EMU_CFG; exit 1; }
grep -q 'selinux=0 systemd.unit=multi-user.target"' .config || { echo A82_CMDLINE_LOST; exit 1; }
grep -q 'A82 SWITCH_ROOT_TO' /tmp/y700/initramfs/init || { echo A82_INIT_LOST; exit 1; }

scripts/config --enable DRM_SIMPLEDRM || { echo A88_CONFIG_TOOL_FAIL; exit 1; }
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/y700/kbuild/a88-olddefconfig.log 2>&1 || { echo A88_OLDDEFCONFIG_FAIL; exit 1; }
grep -E 'CONFIG_(DRM_SIMPLEDRM|DRM_SYSFB_HELPER|DRM_GEM_SHMEM_HELPER|DRM_CLIENT_SETUP|DRM_CLIENT_SELECTION|DRM_FBDEV_EMULATION|FB_Y700|FRAMEBUFFER_CONSOLE)' .config
grep -q 'CONFIG_DRM_SIMPLEDRM=y' .config || { echo A88_SIMPLEDRM_NOT_SET; exit 1; }
grep -q 'CONFIG_FB_Y700=y' .config || { echo A88_FB_Y700_LOST; exit 1; }
grep -q 'CONFIG_FRAMEBUFFER_CONSOLE=y' .config || { echo A88_FBCON_LOST; exit 1; }
grep -q 'CONFIG_CMDLINE_FORCE=y' .config || { echo A88_CMDLINE_FORCE_LOST; exit 1; }

python3 /tmp/y700/kbuild/patch_a88.py || { echo PATCH_A88_FAIL; exit 1; }
grep -q 'y700fb_panel_claimed' drivers/video/fbdev/y700fb.c || { echo A88_PATCH_MISSING; exit 1; }
grep -q 'static bool y700fb_takeover = true;' drivers/video/fbdev/y700fb.c || { echo A81_TAKEOVER_LOST; exit 1; }
grep -q 'static int nvt_fw_chunk = 16384;' drivers/input/touchscreen/novatek-nt36523n-spi.c || { echo TOUCH_CHUNK_LOST; exit 1; }

FW=/tmp/y700/initramfs/lib/firmware/novatek/lenovo-tb320fc.bin
[ "$(wc -c < "$FW")" = "196608" ] || { echo FW_WRONG_SIZE; exit 1; }
grep -q 'CONFIG_INITRAMFS_SOURCE="/tmp/y700/initramfs"' .config || { echo INITRAMFS_CFG_MOVED; exit 1; }
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image || { echo MAKE_FAIL; exit 1; }
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
sha256sum arch/arm64/boot/Image "$B/armada-boot/vmlinuz"

nm vmlinux > "$B/nm-a88.txt" || { echo NM_FAIL; exit 1; }
grep -E ' [tT] simpledrm_probe$| [tT] simpledrm_platform_driver$' "$B/nm-a88.txt" || { echo A88_SIMPLEDRM_SYM_FAIL; exit 1; }
grep -E ' [tT] y700fb_panel_claimed$| [tT] y700fb_probe$' "$B/nm-a88.txt" || { echo A88_FB_SYM_FAIL; exit 1; }
grep -E ' [tT] simplefb_console_on$| [tT] simplefb_console_off$' "$B/nm-a88.txt" || { echo EARLYCON_SYM_FAIL; exit 1; }
strings vmlinux | grep -c 'panel claimed by simpledrm' || { echo A88_HANDOVER_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'simple-framebuffer' || { echo A88_MATCH_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'Y700-FB up fb' || { echo FB_UP_STR_FAIL; exit 1; }
strings vmlinux | grep -c 'selinux=0' || { echo CMDLINE_NOT_IN_IMAGE; exit 1; }

# DTB exactly as A70/A73/A82 left it - A88 is a driver change, not a board change.
export Y700_EXTRA_DISABLE='display-subsystem@ae00000,display-controller@ae01000,displayport-controller@ae90000,dsi@ae94000,dsi@ae96000,phy@ae94400,phy@ae96400,clock-controller@af00000'
unset Y700_A65_BL_OFF
export Y700_A70=1
dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; printf '%s\n' "$dtbout"; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A65 pin skipped' || { echo A65_GUARD_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A70: y700-stub-panel added' || { echo A70_STEP_MISSING; exit 1; }
cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a88.dts" || { echo DTC_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a88.dts" || { echo CHK_FAIL; exit 1; }
diff "$B/chk_a73.dts" "$B/chk_a88.dts" > "$B/a88-dtb.diff" || { echo A88_DTB_DIFFERS; cat "$B/a88-dtb.diff"; exit 1; }
grep -c 'simple-framebuffer' "$B/chk_a88.dts" || { echo A88_FB_NODE_GONE; exit 1; }
echo A88_DTB_SAME_AS_A73

python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a88.img" || { echo PACK_FAIL; exit 1; }
# The pack must carry the Image just built, not the previous round vmlinuz: A88
# ships a string no other kernel here has, so demand it inside the packed image.
strings "$B/out/boot-b-a88.img" | grep -q "panel claimed by simpledrm" || { echo A88_IMAGE_IS_STALE; exit 1; }
strings "$B/out/boot-b-a88.img" | grep -q "simple-framebuffer" || { echo A88_MATCH_NOT_IN_IMAGE; exit 1; }
cp -f "$B/out/boot-b-a88.img" /tmp/y700/e15/ || exit 1
ls -l /tmp/y700/e15/boot-b-a88.img
sha256sum /tmp/y700/e15/boot-b-a88.img
echo "=== a88 end $(date -u) ==="
echo A88_ALL_OK