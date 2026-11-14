#pragma once
#include <stdint.h>

/* Gen2 handoff diagnostics.
 *
 * report_base paints the base-image contract on the ABL splash scanout and
 * holds, so the derived addresses can be read off the panel.  catch_install
 * puts an exception vector table plus its stack into the splash reservation
 * (reserved, no-map, off-screen) and points VBAR at the current EL, so an
 * early fault in the base kernel stops here with PC/ESR/FAR on the panel
 * instead of vanishing into a Qualcomm crashdump.
 */
void kshim_diag_report_base(uint64_t linux_base, uint64_t manifest_address,
                            uint64_t manifest_size, uint64_t dtb,
                            uint64_t arg1, uint64_t arg2, uint64_t arg3);
void kshim_diag_catch_install(void);

void kshim_diag_jump_marker(uint64_t entry);

/* Reached from the vector stub; never returns. */
void kshim_diag_catch_report(uint64_t elr, uint64_t esr, uint64_t far,
                             uint64_t spsr, uint64_t el, uint64_t sp,
                             uint64_t sctlr, uint64_t vector);