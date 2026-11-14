#pragma once
#include <stdint.h>

/* Everything a screen report needs, drawn straight into the ABL splash
 * scanout.  Fill, then text, then clean the frame so the panel sees it. */
void kshim_diag_fb_fill(uint32_t argb);
void kshim_diag_fb_clean(void);
unsigned kshim_diag_fb_puts(unsigned x, unsigned y, const char *s, uint32_t argb);
unsigned kshim_diag_fb_hex(unsigned x, unsigned y, uint64_t v, unsigned digits,
                           uint32_t argb);
unsigned kshim_diag_fb_dec(unsigned x, unsigned y, uint64_t v, uint32_t argb);