/* Vector stubs for the Gen2 handoff catcher.  The table itself is written at
 * runtime into the ABL splash reservation, where every entry loads the stack
 * top and this stub into x10 and branches here; only registers are touched, so
 * nothing has to be mapped except this stub, which runs through the loader's
 * identity mapping.
 *
 * If the base kernel turned the MMU on with page tables that do not cover the
 * splash reservation, the vector fetch already faults before this runs and no
 * report appears; that is the known blind spot of the catcher.
 */
    .text
    .align 6

    .global kshim_diag_catch_entry_addr
/* uint64_t kshim_diag_catch_entry_addr(void) - runtime address of the stub. */
kshim_diag_catch_entry_addr:
    adrp    x0, kshim_diag_catch_entry
    add     x0, x0, :lo12:kshim_diag_catch_entry
    ret

    .global kshim_diag_catch_vectors
/* void kshim_diag_catch_vectors(uint64_t table) - VBAR for the current EL. */
kshim_diag_catch_vectors:
    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    1f
    msr     vbar_el2, x0
    b       2f
1:  msr     vbar_el1, x0
2:  dsb     sy
    isb
    ret

    .align 6
/* x7 already carries the vector index and SP is already the catcher stack. */
kshim_diag_catch_entry:
    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    1f
    mrs     x6, sctlr_el2
    tbz     x6, #0, 3f
    bic     x10, x6, #1
    msr     sctlr_el2, x10
    tlbi    alle2
    b       3f
1:  mrs     x6, sctlr_el1
    tbz     x6, #0, 3f
    bic     x10, x6, #1
    msr     sctlr_el1, x10
    tlbi    alle1
3:  dsb     sy
    isb
    cmp     x9, #2
    b.ne    4f
    mrs     x0, elr_el2
    mrs     x1, esr_el2
    mrs     x2, far_el2
    mrs     x3, spsr_el2
    mrs     x5, sp_el2
    b       5f
4:  mrs     x0, elr_el1
    mrs     x1, esr_el1
    mrs     x2, far_el1
    mrs     x3, spsr_el1
    mrs     x5, sp_el1
5:  mov     x4, x9
    adrp    x16, kshim_diag_catch_report
    add     x16, x16, :lo12:kshim_diag_catch_report
    br      x16