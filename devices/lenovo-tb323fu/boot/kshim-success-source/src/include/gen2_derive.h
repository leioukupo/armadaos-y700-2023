#pragma once
#include <stdint.h>

/* What the Gen2 code1-entry protocol worked out about where the base image
 * sits in memory.  The runtime was appended to the base image, so the base
 * image begins at (address this runtime runs from) - shim_offset.  Three
 * independent ways of locating this runtime are kept, plus the winner and a
 * failure code, because a wrong guess is otherwise invisible: the handoff
 * either jumps into a bus or never happens at all.
 *
 * reason bits: 1 the packed contract is not ours, 2 a contract field is out
 * of range, 3 candidate 1 is not usable, 4 candidate 2, 5 candidate 3,
 * 6 no candidate had an ARM64 header under it. */
typedef struct {
    uint64_t runtime_base[3]; /* startup.S asm, startup.S global, mmu view */
    uint64_t image_base;      /* 0 when nothing could be believed          */
    uint64_t entry;           /* base image entry once derived             */
    unsigned reason;
    unsigned picked;          /* which runtime_base candidate won, 3 none   */
    uint64_t adjust;          /* signed fix-up applied to that candidate    */
    unsigned mode;            /* 0 header verified, 1 after a search,
                               * 2 believed without a header, 3 nothing     */
    uint64_t want;            /* runtime candidate minus shim_offset        */
    unsigned want_flags;      /* 1 inside DRAM, 2 first word is B/BL,
                               * 4 ARMd magic under it                      */
} KSHIM_GEN2_DERIVE;

extern KSHIM_GEN2_DERIVE kshim_gen2_derive;