/* Gen2 handoff diagnostics: paint the base-image contract on the panel, then
 * catch whatever the base kernel does next.
 *
 * The appended runtime is not reserved in the loader's DT, so once the base
 * kernel runs it may reuse those pages.  The ABL splash reservation is
 * reserved and no-map there, and it spans 45 MiB while one frame is 15.6 MiB:
 * the pages a megabyte above the frame are reserved, off-screen and unused, so
 * the vector table and the catcher stack go there and survive the handoff.
 */
#include <stdint.h>
#include <stddef.h>
#include "diag_catch.h"
#include "diag_fb.h"
#include <timer.h>
#include <libfdt.h>
#include <kshim_mmu.h>
#if defined(KSHIM_GEN2_CODE1_ENTRY) && KSHIM_GEN2_CODE1_ENTRY
#include <pack_contract.h>
#include <gen2_derive.h>
#endif

/* Nothing below this is worth a physical read: a wild read is how a
 * diagnostic becomes a bus hang. */
#define GEN2_FLOOR UINT64_C(0x80000000)

/* The same three checks the derivation applies to the address it derived. */
#define GEN2_FLOOR_OK     1u
#define GEN2_MAGIC_OK     2u
#define GEN2_IMAGE_SZ_OK  4u

/* Reserved splash pages above the visible frame: 2 KiB vector table
 * (VBAR wants 2 KiB alignment), then a 16 KiB catcher stack. */
#define SCRATCH_BASE  ((uint64_t)(KSHIM_DIAG_SPLASH_BASE) + \
                       (uint64_t)KSHIM_DIAG_SCRATCH_OFF)
#define VEC_TABLE     (SCRATCH_BASE)
#define VEC_STACK     (SCRATCH_BASE + 0x800ULL)
#define VEC_STACK_TOP (VEC_STACK + 0x4000ULL)
#define VEC_ARGS      (VEC_STACK_TOP)
#define VEC_BYTES     0x800u

#define TXT_FG        0xFF000000u
#define TXT_ON_RED    0xFFFFFFFFu
#define ROW0          40u
#define ROW_H         ((unsigned)(KSHIM_DIAG_FB_SCALE) * 10u)
#define COL0          24u

extern uint64_t kshim_diag_catch_entry_addr(void);
extern void kshim_diag_catch_vectors(uint64_t table);

static uint64_t Reported_entry;
static uint64_t Reported_dtb;
static unsigned Report_next_row;

static unsigned row_y(unsigned row)
{
    return ROW0 + row * ROW_H;
}

static uint64_t current_el(void)
{
    uint64_t v;

    __asm__ volatile("mrs %0, CurrentEL" : "=r"(v));
    return v >> 2;
}

static uint64_t current_sctlr(void)
{
    uint64_t v;

    if (current_el() == 2u)
        __asm__ volatile("mrs %0, sctlr_el2" : "=r"(v));
    else
        __asm__ volatile("mrs %0, sctlr_el1" : "=r"(v));
    return v;
}

static uint64_t current_sp(void)
{
    uint64_t v;

    __asm__ volatile("mov %0, sp" : "=r"(v));
    return v;
}

static void line_str(unsigned row, const char *s, uint32_t fg)
{
    (void)kshim_diag_fb_puts(COL0, row_y(row), s, fg);
}

static unsigned line_hex(unsigned row, const char *label, uint64_t v,
                         unsigned digits, uint32_t fg)
{
    unsigned x = kshim_diag_fb_puts(COL0, row_y(row), label, fg);

    return kshim_diag_fb_hex(x, row_y(row), v, digits, fg);
}

static void hold_ms(uint64_t ms)
{
    const uint64_t start = get_current_time();

    while (get_current_time() - start < ms)
        __asm__ volatile("yield" ::: "memory");
}

#if defined(KSHIM_GEN2_CODE1_ENTRY) && KSHIM_GEN2_CODE1_ENTRY
static uint64_t derive_runtime(unsigned index)
{
    return index < 3u ? kshim_gen2_derive.runtime_base[index] : 0;
}
#endif

void kshim_diag_report_base(uint64_t linux_base, uint64_t manifest_address,
                            uint64_t manifest_size, uint64_t dtb,
                            uint64_t arg1, uint64_t arg2, uint64_t arg3)
{
    const uint64_t sctlr = current_sctlr();
    const uint64_t el = current_el();
    unsigned row = 0;
    unsigned x;

    (void)arg1;
    (void)arg2;
    (void)arg3;
    Reported_entry = linux_base;
    Reported_dtb = dtb;

    kshim_diag_fb_fill(0xFF00FF00u);

    line_str(row++, "Y700 GEN2 HANDOFF c9", TXT_FG);
#if defined(KSHIM_GEN2_CODE1_ENTRY) && KSHIM_GEN2_CODE1_ENTRY
    x = kshim_diag_fb_puts(COL0, row_y(row), "MAG ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), kshim_pack_contract.magic, 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " VER ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row), kshim_pack_contract.version, 8, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "SHM ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row),
                          kshim_pack_contract.shim_offset, 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " BEO ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row),
                      kshim_pack_contract.base_entry_offset, 8, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "MFO ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row),
                          kshim_pack_contract.manifest_offset, 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " MSZ ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row),
                      kshim_pack_contract.manifest_size, 8, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "ASM ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), derive_runtime(0), 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " GLB ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), derive_runtime(1), 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " MMU ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row), derive_runtime(2), 8, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "WANT ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), kshim_gen2_derive.want, 8, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "RAM ", TXT_FG);
    x = kshim_diag_fb_dec(x, row_y(row),
                          (kshim_gen2_derive.want_flags & GEN2_FLOOR_OK) != 0u,
                          TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " SZ ", TXT_FG);
    x = kshim_diag_fb_dec(x, row_y(row),
                          (kshim_gen2_derive.want_flags & GEN2_IMAGE_SZ_OK) != 0u,
                          TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " ARMd ", TXT_FG);
    kshim_diag_fb_dec(x, row_y(row),
                      (kshim_gen2_derive.want_flags & GEN2_MAGIC_OK) != 0u,
                      TXT_FG);
    row++;

    if ((kshim_gen2_derive.want_flags & GEN2_FLOOR_OK) != 0u) {
        const uint64_t want = kshim_gen2_derive.want;

        x = kshim_diag_fb_puts(COL0, row_y(row), "H@W ", TXT_FG);
        x = kshim_diag_fb_hex(x, row_y(row),
            *(const volatile uint32_t *)(uintptr_t)want, 8, TXT_FG);
        x = kshim_diag_fb_puts(x, row_y(row), " ", TXT_FG);
        kshim_diag_fb_hex(x, row_y(row),
            *(const volatile uint32_t *)(uintptr_t)(want + 0x38u), 8, TXT_FG);
    } else {
        line_str(row, "H@W SKIP BELOW RAM", TXT_FG);
    }
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "IMG ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), kshim_gen2_derive.image_base,
                          8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " MD ", TXT_FG);
    x = kshim_diag_fb_dec(x, row_y(row), kshim_gen2_derive.mode, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " PICK ", TXT_FG);
    kshim_diag_fb_dec(x, row_y(row), kshim_gen2_derive.picked, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "RS ", TXT_FG);
    x = kshim_diag_fb_dec(x, row_y(row), kshim_gen2_derive.reason, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " ADJ ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row), kshim_gen2_derive.adjust, 8, TXT_FG);
    row++;
#endif
    x = kshim_diag_fb_puts(COL0, row_y(row), "ENT ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), linux_base, 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " MAN ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row), manifest_address, 8, TXT_FG);
    row++;

    x = kshim_diag_fb_puts(COL0, row_y(row), "DT ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), dtb, 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " MG ", TXT_FG);
    if (dtb >= GEN2_FLOOR)
        kshim_diag_fb_hex(x, row_y(row),
                          *(const volatile uint32_t *)(uintptr_t)dtb,
                          8, TXT_FG);
    else
        kshim_diag_fb_puts(x, row_y(row), "BAD", TXT_FG);
    row++;

    /* What the kernel inherits from the loader: where the loader put the
     * ramdisk, and the RAM bank it was told about.  The base image
     * decompresses right after itself, so these decide whether anything the
     * kernel needs sits in the way. */
    if (dtb >= GEN2_FLOOR && fdt_check_header((const void *)(uintptr_t)dtb) == 0) {
        const void *fdt = (const void *)(uintptr_t)dtb;
        int chosen = fdt_path_offset(fdt, "/chosen");

        x = kshim_diag_fb_puts(COL0, row_y(row), "IRD ", TXT_FG);
        if (chosen >= 0) {
            int len = 0;
            const uint32_t *p = (const uint32_t *)(const void *)
                fdt_getprop(fdt, chosen, "linux,initrd-start", &len);

            if (p != NULL && len >= 4)
                x = kshim_diag_fb_hex(x, row_y(row),
                                      fdt32_to_cpu(p[len / 4 - 1]), 8, TXT_FG);
            else
                x = kshim_diag_fb_puts(x, row_y(row), "NONE", TXT_FG);
            x = kshim_diag_fb_puts(x, row_y(row), " IRE ", TXT_FG);
            p = (const uint32_t *)(const void *)
                fdt_getprop(fdt, chosen, "linux,initrd-end", &len);
            if (p != NULL && len >= 4)
                x = kshim_diag_fb_hex(x, row_y(row),
                                      fdt32_to_cpu(p[len / 4 - 1]), 8, TXT_FG);
            else
                kshim_diag_fb_puts(x, row_y(row), "NONE", TXT_FG);
        } else {
            kshim_diag_fb_puts(x, row_y(row), "NO CHOSEN", TXT_FG);
        }
        row++;

        {
            int mem = fdt_path_offset(fdt, "/memory");
            int len = 0;
            const uint32_t *reg = mem >= 0 ? (const uint32_t *)(const void *)
                fdt_getprop(fdt, mem, "reg", &len) : NULL;

            x = kshim_diag_fb_puts(COL0, row_y(row), "MEM ", TXT_FG);
            if (reg != NULL && len >= 8) {
                x = kshim_diag_fb_hex(x, row_y(row),
                                      fdt32_to_cpu(reg[len / 4 - 2]), 8, TXT_FG);
                x = kshim_diag_fb_puts(x, row_y(row), " SZ ", TXT_FG);
                x = kshim_diag_fb_hex(x, row_y(row),
                                      fdt32_to_cpu(reg[len / 4 - 1]), 8, TXT_FG);
            } else {
                kshim_diag_fb_puts(x, row_y(row), "NONE", TXT_FG);
            }
            row++;
        }

        x = kshim_diag_fb_puts(COL0, row_y(row), "FDTSZ ", TXT_FG);
        kshim_diag_fb_hex(x, row_y(row), fdt_totalsize(fdt), 8, TXT_FG);
        row++;
    }

    x = kshim_diag_fb_puts(COL0, row_y(row), "EL ", TXT_FG);
    x = kshim_diag_fb_dec(x, row_y(row), el, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " SCTLR ", TXT_FG);
    x = kshim_diag_fb_hex(x, row_y(row), sctlr, 8, TXT_FG);
    x = kshim_diag_fb_puts(x, row_y(row), " SP ", TXT_FG);
    kshim_diag_fb_hex(x, row_y(row), current_sp(), 8, TXT_FG);
    row++;

    line_str(row++, linux_base != 0 ? "GO: HANDOFF NEXT"
                                    : "STOP: NO BASE IMAGE", TXT_FG);

    Report_next_row = row;
    kshim_diag_fb_clean();
    hold_ms((uint64_t)KSHIM_DIAG_REPORT_HOLD_MS);
}

/* Painted immediately before the branch into the base image.  The panel keeps
 * showing whatever the loader scanout holds, so a colour that only exists here
 * is the only proof that the branch instruction was actually reached: if the
 * panel turns blue and stays blue, the base kernel was entered and produced
 * nothing; if it never turns blue, the shim stopped short of the jump. */
void kshim_diag_jump_marker(uint64_t entry)
{
    unsigned row = 0;
    unsigned x;

    kshim_diag_fb_fill(0xFF0000FFu);

    x = kshim_diag_fb_puts(COL0, row_y(row), "JUMPING NOW", TXT_ON_RED);
    row++;
    x = kshim_diag_fb_puts(COL0, row_y(row), "ENT ", TXT_ON_RED);
    kshim_diag_fb_hex(x, row_y(row), entry, 8, TXT_ON_RED);
    row++;
    line_str(row++, "NO VBAR  NEW SP", TXT_ON_RED);
    line_str(row++, "BLUE FOREVER = KERNEL SILENT", TXT_ON_RED);

    kshim_diag_fb_clean();
}

/* MOV/MOVK/ADD SP/BR encodings, enough to build a vector entry that loads an
 * absolute address and branches to it without touching memory first. */
static uint32_t enc_movz(unsigned rt, uint32_t imm16)
{
    return 0xD2800000u | (imm16 << 5) | rt;
}

static uint32_t enc_movk(unsigned rt, uint32_t imm16, unsigned shift)
{
    return 0xF2800000u | (shift << 21) | (imm16 << 5) | rt;
}

static unsigned emit_load(unsigned *w, unsigned n, uint64_t v, unsigned rt)
{
    w[n++] = enc_movz(rt, (uint32_t)(v & 0xFFFFu));
    for (unsigned hw = 1u; hw < 4u; ++hw)
        if (((v >> (hw * 16u)) & 0xFFFFu) != 0u)
            w[n++] = enc_movk(rt, (uint32_t)((v >> (hw * 16u)) & 0xFFFFu), hw);
    return n;
}

void kshim_diag_catch_install(void)
{
    const uint64_t stub = kshim_diag_catch_entry_addr();
    volatile uint32_t *table = (volatile uint32_t *)(uintptr_t)VEC_TABLE;
    unsigned ok = 1u;

    for (unsigned entry = 0u; entry < 16u; ++entry) {
        uint32_t w[16];
        unsigned n = 0u;

        n = emit_load(w, n, VEC_STACK_TOP, 10u);
        w[n++] = 0x91000000u | (10u << 5) | 31u; /* add sp, x10, #0 */
        w[n++] = enc_movz(7u, entry);
        n = emit_load(w, n, stub, 10u);
        w[n++] = 0xD61F0000u | (10u << 5);       /* br x10 */
        for (unsigned i = 0u; i < n; ++i)
            table[entry * 0x20u + i] = w[i];
    }

    for (unsigned off = 0u; off < VEC_BYTES; off += 64u) {
        __asm__ volatile("dc civac, %0" :: "r"(VEC_TABLE + off) : "memory");
        __asm__ volatile("ic ivau, %0" :: "r"(VEC_TABLE + off) : "memory");
    }
    __asm__ volatile("dsb sy" ::: "memory");
    __asm__ volatile("isb" ::: "memory");

    if (table[0] != (0xD2800000u | ((uint32_t)(VEC_STACK_TOP & 0xFFFFu) << 5) | 10u))
        ok = 0u;

    kshim_diag_catch_vectors(VEC_TABLE);

    {
        volatile uint64_t *args = (volatile uint64_t *)(uintptr_t)VEC_ARGS;
        uint64_t mark;

        __asm__ volatile("mrs %0, vbar_el1" : "=r"(mark));
        args[0] = 0x4B5348494D4F4F53ULL; /* KSHIMOOS */
        args[1] = VEC_TABLE;
        args[2] = mark;
        args[3] = current_el();
    }

    {
        unsigned row = Report_next_row;
        unsigned x = kshim_diag_fb_puts(COL0, row_y(row), "CATCH TABLE ", TXT_FG);

        x = kshim_diag_fb_hex(x, row_y(row), VEC_TABLE, 16, TXT_FG);
        x = kshim_diag_fb_puts(x, row_y(row), " ", TXT_FG);
        kshim_diag_fb_puts(x, row_y(row), ok != 0u ? "ARMED" : "READBACK BAD", TXT_FG);
        Report_next_row = row + 1u;
    }
    kshim_diag_fb_clean();
}

static const char *ec_name(unsigned ec)
{
    switch (ec) {
    case 0x01u: return "TRAP WFX";
    case 0x05u: return "SYS REG";
    case 0x0Cu: return "UNALIGNED PC";
    case 0x0Du: return "BRK";
    case 0x0Eu: return "ILLEGAL EL0";
    case 0x0Fu: return "ILLEGAL EL1";
    case 0x15u: return "PC ALIGN";
    case 0x20u: return "INS ABT LOW";
    case 0x21u: return "INS ABT SAME";
    case 0x22u: return "PC ALIGN";
    case 0x25u: return "WATCH LOW";
    case 0x26u: return "WATCH SAME";
    case 0x2Du: return "ST BT SAME";
    case 0x2Fu: return "ASYNC SERROR";
    case 0x30u: return "DAT ABT LOW";
    case 0x31u: return "DAT ABT LOW";
    case 0x32u: return "DAT ABT SAME";
    case 0x33u: return "DAT ABT SAME";
    case 0x34u: return "INS ABT LOW";
    case 0x35u: return "INS ABT SAME";
    case 0x36u: return "INS ABT SAME";
    case 0x37u: return "INS ABT SAME";
    case 0x3Cu: return "ST BT LOW";
    case 0x3Du: return "ST BT LOW";
    default: return "UNKNOWN EC";
    }
}

void kshim_diag_catch_report(uint64_t elr, uint64_t esr, uint64_t far,
                             uint64_t spsr, uint64_t el, uint64_t sp,
                             uint64_t sctlr, uint64_t vector)
{
    unsigned row = 0;
    unsigned x;
    volatile uint64_t *args = (volatile uint64_t *)(uintptr_t)VEC_ARGS;

    args[4] = elr;
    args[5] = esr;
    args[6] = far;
    args[7] = spsr;

    kshim_diag_fb_fill(0xFFFF0000u);

    line_str(row++, "!! KSHIM CAUGHT AN EXCEPTION !!", TXT_ON_RED);
    x = kshim_diag_fb_puts(COL0, row_y(row), "VEC ", TXT_ON_RED);
    x = kshim_diag_fb_dec(x, row_y(row), vector, TXT_ON_RED);
    x = kshim_diag_fb_puts(x, row_y(row), "   EL ", TXT_ON_RED);
    x = kshim_diag_fb_dec(x, row_y(row), el, TXT_ON_RED);
    x = kshim_diag_fb_puts(x, row_y(row), "   EC ", TXT_ON_RED);
    x = kshim_diag_fb_hex(x, row_y(row), (esr >> 26) & 0x3Fu, 2, TXT_ON_RED);
    x = kshim_diag_fb_puts(x, row_y(row), "  ", TXT_ON_RED);
    kshim_diag_fb_puts(x, row_y(row), ec_name((unsigned)((esr >> 26) & 0x3Fu)),
                       TXT_ON_RED);
    row++;

    line_hex(row++, "PC   ", elr, 16, TXT_ON_RED);
    line_hex(row++, "ESR  ", esr, 8, TXT_ON_RED);
    line_hex(row++, "FAR  ", far, 16, TXT_ON_RED);
    line_hex(row++, "SP   ", sp, 16, TXT_ON_RED);
    line_hex(row++, "SPSR ", spsr, 8, TXT_ON_RED);
    line_hex(row++, "SCTLR", sctlr, 8, TXT_ON_RED);
    line_hex(row++, "ENT  ", Reported_entry, 16, TXT_ON_RED);
    line_hex(row++, "DT   ", Reported_dtb, 16, TXT_ON_RED);
    line_str(row++, "STOPPED HERE - READ THIS", TXT_ON_RED);

    kshim_diag_fb_clean();
    for (;;)
        __asm__ volatile("wfe" ::: "memory");
}