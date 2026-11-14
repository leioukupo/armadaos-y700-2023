/* Gen2 code1-entry contract.
 *
 * The Gen2 base image is entered from the branch the ARM64 image header
 * carries in code1.  When that branch points at this runtime there is no
 * patched instruction inside the base kernel to call us, so there is no
 * entry site to recover the base-image contract from: the runtime carries
 * the contract itself and the packer fills it in.
 *
 * That keeps the base kernel text byte-identical while the shim runs.  The
 * old protocol wrote five words back into primary_entry and relied on the
 * kernel image being writable and on self-modifying-code cache maintenance;
 * neither can be assumed here, and getting either wrong ends in a Qualcomm
 * crashdump instead of the base kernel.
 */
#pragma once

#include <stdint.h>

/* "KPRT": packed runtime contract.  The packer scans the runtime image for
 * magic+version followed by four zero quads, so the layout below has to stay
 * a fixed 40 bytes with no padding. */
#define KSHIM_PACK_CONTRACT_MAGIC 0x5452504BU
#define KSHIM_PACK_CONTRACT_VERSION 1U
#define KSHIM_PACK_CONTRACT_BYTES 40U

typedef struct {
    uint32_t magic;
    uint32_t version;
    /* All four offsets are relative to the start of the base image, which is
     * also where the runtime would have been copied: the runtime locates the
     * base image by subtracting shim_offset from the address it runs at. */
    uint64_t shim_offset;
    uint64_t base_entry_offset;
    uint64_t manifest_offset;
    uint64_t manifest_size;
} KSHIM_PACK_CONTRACT;

#if defined(KSHIM_GEN2_CODE1_ENTRY) && KSHIM_GEN2_CODE1_ENTRY
/* volatile because the values are not the ones the compiler saw: the repacker
 * rewrites this block inside the runtime image after the object file has been
 * linked, and every field has to be read from memory to be believed. */
extern volatile const KSHIM_PACK_CONTRACT kshim_pack_contract;
#endif
