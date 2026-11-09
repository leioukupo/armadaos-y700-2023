// SPDX-License-Identifier: GPL-2.0
/*
 * fbdev drawn straight onto the framebuffer the Android bootloader left running.
 *
 * ABL brings the panel up for the splash screen and never tears the pipeline
 * down: the DPU keeps scanning the splash buffer, so anything Linux writes to
 * that physical range is what the panel shows - no DSI PLL, no GDSC, no panel
 * init in the kernel at all.  drivers/tty/serial/earlycon-simplefb.c has used
 * that path as its console since A14, which is the proof it works on this board.
 *
 * The MSM KMS route cannot reach it: msm_kms_init_vm() demands a mapped display
 * SMMU and bails out with -ENODEV without one (A54), and adding the SMMU back is
 * the bus-stall that A47 measured.  So the fbdev layer is supplied here instead:
 * one ioremap, one fb_info, no clocks, no regulators, no power domains and no
 * component master - nothing that can stall a bus or defer forever.
 *
 * Geometry is read from the simple-framebuffer node the bootloader left in
 * /chosen, with this board's actual splash layout compiled in as a fallback so a
 * missing or malformed node cannot lose the panel.  The memory is `no-map`
 * reserved (splash-region@b8000000 in reserved-memory), so the page allocator
 * can never hand it out from under us, and the region is write-combined for the
 * same reason the earlycon maps it write-combined: the display engine reads
 * plain DRAM and is not in the CPU's cache-coherency domain.
 *
 * The earlycon draws on the very same buffer, so it is asked to stop before
 * fbcon takes the text console over - two writers on one panel give noise, not a
 * console.  Registration happens at late_initcall() so this driver is the last
 * thing to touch the panel during boot and the first thing the panel shows
 * afterwards.
 */
#include <linux/earlycon_simplefb.h>
#include <linux/fb.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/string.h>

/* what the Lenovo Y700 (TB320FC) ABL actually hands over */
#define Y700FB_BASE	0xb8000000
#define Y700FB_SIZE	((size_t)6400 * 2560)
#define Y700FB_WIDTH	1600
#define Y700FB_HEIGHT	2560
#define Y700FB_STRIDE	6400

struct y700fb_par {
	u32	palette[16];
	bool	taken_over;	/* the earlycon was told to stop drawing */
};

static int y700fb_setcolreg(u_int regno, u_int red, u_int green, u_int blue,
			    u_int transp, struct fb_info *info)
{
	u32 *pal = info->pseudo_palette;

	if (regno >= 16)
		return -EINVAL;

	pal[regno] = ((red >> (16 - info->var.red.length)) << info->var.red.offset) |
		     ((green >> (16 - info->var.green.length)) << info->var.green.offset) |
		     ((blue >> (16 - info->var.blue.length)) << info->var.blue.offset);
	return 0;
}

static const struct fb_ops y700fb_ops = {
	.owner		= THIS_MODULE,
	FB_DEFAULT_IOMEM_OPS,
	.fb_setcolreg	= y700fb_setcolreg,
};

/*
 * Read the splash geometry out of the live devicetree.  Nothing fails here: the
 * compiled-in layout is what this board gives us, so a bad node only costs the
 * chance that the vendor values differed.
 */
static void y700fb_read_geom(struct device *dev, phys_addr_t *base,
			     size_t *size, u32 *width, u32 *height, u32 *stride)
{
	struct device_node *np;
	struct resource res;
	const char *fmt = NULL;

	*base = Y700FB_BASE;
	*size = Y700FB_SIZE;
	*width = Y700FB_WIDTH;
	*height = Y700FB_HEIGHT;
	*stride = Y700FB_STRIDE;

	np = of_find_compatible_node(NULL, NULL, "simple-framebuffer");
	if (!np) {
		dev_info(dev, "no simple-framebuffer node, using compiled-in splash\n");
		return;
	}

	if (!of_address_to_resource(np, 0, &res) && resource_size(&res)) {
		*base = res.start;
		*size = resource_size(&res);
	}
	of_property_read_u32(np, "width", width);
	of_property_read_u32(np, "height", height);
	of_property_read_u32(np, "stride", stride);
	of_property_read_string(np, "format", &fmt);
	of_node_put(np);

	/*
	 * Only the depth this driver maps is 4 bytes per pixel; anything else
	 * would put colour in the wrong byte lane, which looks like a dead panel.
	 */
	if (fmt && strcmp(fmt, "a8r8g8b8") && strcmp(fmt, "x8r8g8b8")) {
		dev_warn(dev, "format %s unsupported, falling back to 1600x2560 a8r8g8b8\n",
			 fmt);
		*base = Y700FB_BASE;
		*size = Y700FB_SIZE;
		*width = Y700FB_WIDTH;
		*height = Y700FB_HEIGHT;
		*stride = Y700FB_STRIDE;
		return;
	}

	if (!*width || !*height || *stride < *width * 4 ||
	    *size < (size_t)*stride * *height) {
		dev_warn(dev, "node geometry %ux%u stride %u size %zu is bad, using compiled-in splash\n",
			 *width, *height, *stride, *size);
		*base = Y700FB_BASE;
		*size = Y700FB_SIZE;
		*width = Y700FB_WIDTH;
		*height = Y700FB_HEIGHT;
		*stride = Y700FB_STRIDE;
	}
}

static int y700fb_probe(struct platform_device *pdev)
{
	struct fb_info *info;
	struct y700fb_par *par;
	phys_addr_t base;
	size_t visible, mapped;
	u32 width, height, stride;
	int ret;

	y700fb_read_geom(&pdev->dev, &base, &mapped, &width, &height, &stride);
	visible = (size_t)stride * height;

	info = framebuffer_alloc(sizeof(struct y700fb_par), &pdev->dev);
	if (!info)
		return -ENOMEM;

	par = info->par;
	platform_set_drvdata(pdev, info);

	/*
	 * The ABL splash region is bigger than one frame; only the frame the
	 * engine scans is exposed, so /dev/fb0 cannot run off the end of it.
	 */
	if (mapped > visible)
		mapped = visible;

	info->screen_base = ioremap_wc((resource_size_t)base, mapped);
	if (!info->screen_base) {
		framebuffer_release(info);
		return -ENOMEM;
	}

	info->fix = (struct fb_fix_screeninfo) {
		.id		= "y700abl",
		.smem_start	= (unsigned long)base,
		.smem_len	= mapped,
		.type		= FB_TYPE_PACKED_PIXELS,
		.visual		= FB_VISUAL_TRUECOLOR,
		.xpanstep	= 0,
		.ypanstep	= 0,
		.ywrapstep	= 0,
		.line_length	= stride,
		.accel		= FB_ACCEL_NONE,
	};

	info->var = (struct fb_var_screeninfo) {
		.xres		= width,
		.yres		= height,
		.xres_virtual	= width,
		.yres_virtual	= height,
		.bits_per_pixel	= 32,
		.red		= { .offset = 16, .length = 8 },
		.green		= { .offset = 8,  .length = 8 },
		.blue		= { .offset = 0,  .length = 8 },
		.transp		= { .offset = 24, .length = 8 },
		.activate	= FB_ACTIVATE_NOW,
		.height		= -1,
		.width		= -1,
		.vmode		= FB_VMODE_NONINTERLACED,
	};

	info->fbops = &y700fb_ops;
	info->pseudo_palette = par->palette;

	ret = fb_alloc_cmap(&info->cmap, 256, 0);
	if (ret) {
		iounmap(info->screen_base);
		framebuffer_release(info);
		return ret;
	}

	ret = register_framebuffer(info);
	if (ret < 0) {
		dev_err(&pdev->dev, "cannot register fb: %d\n", ret);
		fb_dealloc_cmap(&info->cmap);
		iounmap(info->screen_base);
		framebuffer_release(info);
		return ret;
	}

	/*
	 * fbcon has had the panel since register_framebuffer(); the earlycon
	 * would otherwise keep painting its own text over it and page-turning,
	 * which wipes whatever fbcon or /dev/fb0 just drew.
	 */
	simplefb_console_off();
	par->taken_over = true;

	pr_emerg("Y700-FB up fb%d base=0x%llx size=0x%zx %ux%u stride=%u a8r8g8b8\n",
		 info->node, (unsigned long long)base, mapped, width, height, stride);

	return 0;
}

static void y700fb_remove(struct platform_device *pdev)
{
	struct fb_info *info = platform_get_drvdata(pdev);

	unregister_framebuffer(info);
	fb_dealloc_cmap(&info->cmap);
	iounmap(info->screen_base);
	framebuffer_release(info);
}

static struct platform_driver y700fb_driver = {
	.probe	= y700fb_probe,
	.remove	= y700fb_remove,
	.driver	= {
		.name		= "y700-fb",
	},
};

/*
 * Late on purpose: this is the last initcall level, so no driver probed before
 * it can be affected, and the fbcon handover happens after the boot log has
 * already been read off the panel by the earlycon.
 */
int __init y700fb_register(void);

int __init y700fb_register(void)
{
	static struct resource y700fb_res = {
		.start	= Y700FB_BASE,
		.end	= Y700FB_BASE + Y700FB_SIZE - 1,
		.flags	= IORESOURCE_MEM,
	};
	static const struct platform_device_info y700fb_info __initconst = {
		.name		= "y700-fb",
		.id		= -1,
		.res		= &y700fb_res,
		.num_res	= 1,
	};
	struct platform_device *pdev;
	int ret;

	ret = platform_driver_register(&y700fb_driver);
	if (ret) {
		pr_emerg("Y700-FB driver register rc=%d\n", ret);
		return ret;
	}

	pdev = platform_device_register_full(&y700fb_info);
	if (IS_ERR(pdev)) {
		pr_emerg("Y700-FB device register rc=%ld\n", PTR_ERR(pdev));
		platform_driver_unregister(&y700fb_driver);
		return PTR_ERR(pdev);
	}

	return 0;
}
late_initcall(y700fb_register);

MODULE_DESCRIPTION("fbdev on the Lenovo Y700 ABL splash framebuffer");
MODULE_LICENSE("GPL");
