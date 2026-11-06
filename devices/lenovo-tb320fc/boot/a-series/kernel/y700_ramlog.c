// SPDX-License-Identifier: GPL-2.0
/*
 * Y700 (Lenovo TB320FC / SM8475) bring-up instrument - local hack, not
 * upstream material.
 *
 * A1w never showed a previous-boot tail even though the ring was mapped: the
 * y7l_map entry really is the first one between __con_initcall_start and
 * __con_initcall_end, so console_initcall() does run.  Two independent reasons
 * could still eat the tail, and A1x removes both:
 *
 *  - register_console() clears CON_ENABLED for non-boot consoles, so the mirror
 *    registered by A1t may have been handed nothing at all.  A1x does not
 *    register a console: kernel/printk/printk.c calls y700_ramlog_store() once
 *    per formatted record from console_emit_next_record(), *before* the console
 *    write, so the last line of a dying boot is stored even when writing it to
 *    the panel is what kills the box.
 *  - the ring sat at 0xf0200000, which is plain DRAM as far as the board
 *    firmware is concerned (only our DTB reserves it), so UEFI was free to
 *    reuse it while the reset ran.  A1x writes three rings in three kinds of
 *    memory on every record:
 *      A 0x9f500000  camera_region - reserved (no-map) by the board DT and
 *                    loaded by nothing here, so the firmware keeps its hands
 *                    off it.  no-map keeps it out of the linear map, hence
 *                    memremap() instead of phys_to_virt().
 *      B 0xa7000000  plain DRAM in the low bank, reserved only by our DTB.
 *      C 0xf0200000  top of the second DDR bank - what A1w used.
 *    If A survives while B and C do not, unreserved DRAM is being reused.
 *
 * y7l_init() prints every ring header (magic/boot/head) with pr_emerg, so a
 * photograph of an early page says which kind of address survives the watchdog
 * reset and whether the mirror is being fed at all.
 */
#include <linux/array_size.h>
#include <linux/delay.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/memremap.h>
#include <linux/minmax.h>
#include <linux/printk.h>
#include <linux/string.h>
#include <linux/types.h>

#include <asm/cacheflush.h>

#define Y7L_TOTAL	0x00100000UL
#define Y7L_HDR		0x1000UL
#define Y7L_DATA	(Y7L_TOTAL - Y7L_HDR)
#define Y7L_MAGIC	0x59374c32u	/* "Y7L2", the A1x layout */
#define Y7L_TAIL	8192
#define Y7L_MAXLINE	60

struct y7l_hdr {
	u32 magic;
	u32 boot;
	u32 head;
	u32 spare;
};

struct y7l_ring {
	phys_addr_t phys;
	char	tag;
	struct y7l_hdr *hdr;
	u8	*data;
	u32	head;
};

static struct y7l_ring y7l_ring[] = {
	{ 0x9f500000, 'A', NULL, NULL, 0 },	/* camera_region (firmware-owned) */
	{ 0xa7000000, 'B', NULL, NULL, 0 },	/* plain low DRAM, our DTB reserve */
	{ 0xf0200000, 'C', NULL, NULL, 0 },	/* top of DDR bank 2, the A1w spot */
};

static bool y7l_live;
static u64 y7l_seq_last = ~0ULL;
static u32 y7l_boot_nr;
static u32 y7l_written;

static u32 y7l_prev_boot;
static u32 y7l_prev_head;
static size_t y7l_prev_len;
static char y7l_prev_tag = '-';
static char y7l_prev[Y7L_TAIL + 1];

/* Clean to the Point of Coherence: after a watchdog reset nothing else will
 * ever write these cache lines back to DRAM. */
static void y7l_poc(const void *start, size_t len)
{
	dcache_clean_inval_poc((unsigned long)start, (unsigned long)start + len);
}

/* One formatted printk record, copied into every mapped ring.  Called with the
 * console_lock held and possibly with interrupts disabled, so it must not print
 * or sleep; printk deduplicates by record sequence because each record is
 * emitted once per console. */
void y700_ramlog_store(const char *s, unsigned int count, u64 seq)
{
	unsigned int i;

	if (!y7l_live)
		return;
	if (seq == y7l_seq_last)
		return;
	y7l_seq_last = seq;
	y7l_written += count;

	for (i = 0; i < ARRAY_SIZE(y7l_ring); i++) {
		struct y7l_ring *r = &y7l_ring[i];
		size_t first, off = r->head % Y7L_DATA;

		if (!r->data)
			continue;
		if (count > Y7L_DATA) {
			s += count - Y7L_DATA;
			count = Y7L_DATA;
			off = 0;
		}
		first = min_t(size_t, count, Y7L_DATA - off);
		memcpy(r->data + off, s, first);
		y7l_poc(r->data + off, first);
		if (count - first) {
			memcpy(r->data, s + first, count - first);
			y7l_poc(r->data, count - first);
		}
		r->head += count;
		r->hdr->head = r->head;
		y7l_poc(&r->hdr->head, sizeof(r->hdr->head));
	}
}

/* copy the @len bytes that end at ring position @head out of the ring */
static size_t y7l_snap(struct y7l_ring *r, char *dst, u32 head, size_t len)
{
	u32 start = head - (u32)len;
	size_t off = start % Y7L_DATA, first = min_t(size_t, len, Y7L_DATA - off);

	memcpy(dst, r->data + off, first);
	if (len - first)
		memcpy(dst + first, r->data, len - first);
	dst[len] = '\0';
	return len;
}

static int __init y7l_init(void)
{
	struct y7l_ring *prev = NULL;
	u32 boot = 0;
	unsigned int i, mapped = 0;

	for (i = 0; i < ARRAY_SIZE(y7l_ring); i++) {
		struct y7l_ring *r = &y7l_ring[i];
		void *v = memremap(r->phys, Y7L_TOTAL, MEMREMAP_WB);
		u32 magic, hboot, head;

		if (!v) {
			pr_emerg("Y700-RAMLOG %c phys=%pap memremap FAILED\n",
				 r->tag, &r->phys);
			continue;
		}
		mapped++;
		r->hdr = v;
		r->data = (u8 *)v + Y7L_HDR;
		magic = r->hdr->magic;
		hboot = r->hdr->boot;
		head = r->hdr->head;
		pr_emerg("Y700-RAMLOG %c phys=%pap magic=%08x boot=%u head=%u\n",
			 r->tag, &r->phys, magic, hboot, head);
		if (magic == Y7L_MAGIC && head && head <= Y7L_DATA * 64) {
			if (hboot > boot)
				boot = hboot;
			if (!prev)
				prev = r;
		}
	}

	if (prev) {
		y7l_prev_boot = prev->hdr->boot;
		y7l_prev_head = prev->hdr->head;
		y7l_prev_len = y7l_snap(prev, y7l_prev, prev->hdr->head,
				       min_t(u32, prev->hdr->head, Y7L_TAIL));
		y7l_prev_tag = prev->tag;
	} else {
		pr_emerg("Y700-RAMLOG: no ring carried a tail - DRAM does not survive this reset\n");
	}

	y7l_boot_nr = boot + 1;
	for (i = 0; i < ARRAY_SIZE(y7l_ring); i++) {
		struct y7l_ring *r = &y7l_ring[i];

		if (!r->hdr)
			continue;
		r->head = 0;
		r->hdr->magic = 0;
		y7l_poc(&r->hdr->magic, sizeof(r->hdr->magic));
		r->hdr->boot = y7l_boot_nr;
		r->hdr->head = 0;
		r->hdr->spare = Y7L_MAGIC ^ y7l_boot_nr;
		r->hdr->magic = Y7L_MAGIC;
		y7l_poc(r->hdr, sizeof(*r->hdr));
	}

	y7l_seq_last = ~0ULL;
	y7l_live = true;
	pr_emerg("Y700-RAMLOG boot=%u mapped=%u prev=%c prevbytes=%zu\n",
		 y7l_boot_nr, mapped, prev ? prev->tag : '-', y7l_prev_len);
	return 0;
}
console_initcall(y7l_init);

/*
 * Print the last @lines console lines of the previous boot, one line each,
 * with the "[   sec.us] " prefix stripped so they survive the 33-column
 * framebuffer console.
 */
void y700_ramlog_replay(int lines)
{
	static int starts[Y7L_MAXLINE * 8];
	static int lens[Y7L_MAXLINE * 8];
	int n = 0, k, st = -1;
	size_t i;

	if (lines <= 0 || lines > (int)ARRAY_SIZE(starts))
		lines = 24;
	if (!y7l_prev_len) {
		pr_emerg("Y700 RAMLOG: previous boot log is empty (no ring survived, or the mirror is not fed)\n");
		return;
	}
	for (i = 0; i < y7l_prev_len && n < (int)ARRAY_SIZE(starts); i++) {
		if (y7l_prev[i] != '\n') {
			if (st < 0)
				st = i;
			continue;
		}
		if (st >= 0 && i > (size_t)st) {
			starts[n] = st;
			lens[n] = i - st;
			n++;
		}
		st = -1;
	}
	pr_emerg("Y700 RAMLOG ring=%c prevboot=%u bytes=%u lines=%d (last %d)\n",
		 y7l_prev_tag, y7l_prev_boot, y7l_prev_head, n,
		 min_t(int, n, lines));
	for (k = max_t(int, 0, n - lines); k < n; k++) {
		const char *s = y7l_prev + starts[k];
		int l = lens[k];

		if (l > 2 && s[0] == '[') {
			int j = 0;

			while (j < l && s[j] != ']')
				j++;
			if (j < l && j < 20) {
				for (j++; j < l && s[j] == ' '; j++)
					;
				s += j;
				l -= j;
			}
		}
		pr_emerg("PV|%.*s\n", min_t(int, l, Y7L_MAXLINE), s);
	}
}

unsigned int y700_ramlog_boot_nr(void)
{
	return y7l_boot_nr;
}

/* bytes mirrored into the rings by this boot so far - proves the feed works */
unsigned int y700_ramlog_this_bytes(void)
{
	return y7l_written;
}

bool y700_ramlog_have_prev(void)
{
	return y7l_prev_len != 0;
}

/*
 * Unattended bring-up: nobody is standing there with a camera at second 8, so
 * once a tail of the previous boot is in a ring, stop the boot loop here and
 * keep re-printing the lines closest to the death.  The CPU idles and the panel
 * holds the same page, which is the only thing that survives for hours on a
 * battery.  y700_ramlog_replay() prints oldest-first, so what stays visible is
 * exactly the tail of the dying boot.
 */
void y700_ramlog_park(void)
{
	pr_emerg("Y700 RAMLOG PARK boot=%u: photograph this page, loop stopped on purpose\n",
		 y7l_boot_nr);
	for (;;) {
		y700_ramlog_replay(14);
		pr_emerg("== PARK boot=%u ring=%c: same page every 10s, hold power ==\n",
			 y7l_boot_nr, y7l_prev_tag);
		msleep(10000);
	}
}

/*
 * Y700: freeze the panel without printing another line.  When no ring survived
 * the reset there is nothing to replay, so instead stop the boot inside the
 * deadly level and let the panel keep the LIVE tail this boot has already
 * written - the initcall_debug "calling ..." lines.
 */
void y700_ramlog_freeze(void)
{
	pr_emerg("Y700-FREEZE: panel frozen, nothing more prints - photograph it, hold power to escape\n");
	for (;;)
		msleep(60000);
}
