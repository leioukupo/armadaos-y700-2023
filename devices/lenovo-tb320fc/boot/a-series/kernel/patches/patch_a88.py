#!/usr/bin/env python3
# A88 = A82 + the ABL splash memory becomes a real KMS device.
#
# CONFIG_DRM_SIMPLEDRM was never on, so the panel was only ever an fbdev we drew
# on by hand.  The board DTB already carries /chosen/framebuffer@b8000000 as a
# proper simple-framebuffer (1600x2560 a8r8g8b8, stride 6400), and
# of_platform_default_populate_init() explicitly creates a platform device for
# /chosen's simple-framebuffer child, so turning the driver on gives us
# /dev/dri/card0 with a fixed 1600x2560 CRTC and no clocks, regulators, SMMU or
# GDSC to fight over - which is what weston/cage/Xwayland need and what a plain
# fbdev can never give them.
#
# Two fbdev writers on one panel is noise, so once simpledrm has bound that node,
# y700fb stops registering its own fb and only turns the earlycon off (that hand
# over is still ours to do, or the earlycon keeps painting text over DRM).
import sys

P = "drivers/video/fbdev/y700fb.c"

OLD_INC = "#include <linux/of.h>\n"
NEW_INC = "#include <linux/of.h>\n#include <linux/of_platform.h>\n"

OLD_PROBE = "static int y700fb_probe(struct platform_device *pdev)\n{\n"
NEW_PROBE = '''/*
 * With CONFIG_DRM_SIMPLEDRM the same splash memory is already a DRM device by
 * the time this late_initcall runs: the platform device for /chosen's
 * simple-framebuffer child is created at arch_initcall_sync and simpledrm binds
 * it at device_initcall.  Ask the DT node who owns it rather than counting fbs -
 * num_registered_fb is not exported, and an unbound device proves nothing.
 */
static bool y700fb_panel_claimed(void)
{
	struct device_node *np;
	struct platform_device *fb_pdev;
	bool claimed = false;

	np = of_find_compatible_node(NULL, NULL, "simple-framebuffer");
	if (!np)
		return false;
	fb_pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (fb_pdev) {
		claimed = fb_pdev->dev.driver != NULL;
		put_device(&fb_pdev->dev);
	}
	return claimed;
}

static int y700fb_probe(struct platform_device *pdev)
{
'''

OLD_GEOM = "\ty700fb_read_geom(&pdev->dev, &base, &mapped, &width, &height, &stride);\n"
NEW_GEOM = '''	/*
	 * DRM owns the glass now: one writer only.  The earlycon still has to be
	 * told to stop, or it keeps painting its own text over the DRM console.
	 */
	if (y700fb_panel_claimed()) {
		simplefb_console_off();
		pr_emerg("Y700-FB panel claimed by simpledrm, earlycon off, no second fb\\n");
		return -EBUSY;
	}

''' + OLD_GEOM

with open(P, encoding="utf-8") as handle:
    src = handle.read()

if "y700fb_panel_claimed" in src:
    print("A88_PATCH_ALREADY_APPLIED")
else:
    for old in (OLD_INC, OLD_PROBE, OLD_GEOM):
        if src.count(old) != 1:
            print("A88_ANCHOR_COUNT", src.count(old), repr(old[:48]))
            sys.exit(1)
    src = src.replace(OLD_INC, NEW_INC, 1)
    src = src.replace(OLD_PROBE, NEW_PROBE, 1)
    src = src.replace(OLD_GEOM, NEW_GEOM, 1)
    with open(P, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(src)
    print("A88_PATCH_APPLIED simpledrm-handover")

with open(P, encoding="utf-8") as handle:
    src = handle.read()
for marker in ("#include <linux/of_platform.h>",
               "static bool y700fb_panel_claimed(void)",
               "panel claimed by simpledrm, earlycon off",
               "return -EBUSY;",
               "static bool y700fb_takeover = true;"):
    if marker not in src:
        print("A88_POSTCOND_MISSING " + marker)
        sys.exit(1)
print("A88_PATCH_OK")