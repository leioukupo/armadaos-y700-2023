/* SPDX-License-Identifier: MIT */
/*
 * tests/tb320fc_dt_probe.c
 *
 * Offline probe for TB320FC / SM8475 ("Cape"/"CapeP"): it runs the kShimC
 * device-tree gates against the captured vendor tree (vendor_boot vb_02 base
 * plus dtbo_14 overlay) and prints the exact rejection stage, so the missing
 * SoC support is observable without hardware. Local tool, not upstream.
 */
#include "qcom_dt.h"
#include "device_info.h"
#include "qcom_keys_fdt.h"
#include "qcom_keys.h"

#include <libfdt.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WORK_SIZE (8u * 1024u * 1024u)

static unsigned long g_mmio_reads;

static uint32_t probe_read32(void *context, uintptr_t address)
{
    (void)context;
    (void)address;
    ++g_mmio_reads;
    return 0u;
}

static void probe_write32(void *context, uintptr_t address, uint32_t value)
{
    (void)context;
    (void)address;
    (void)value;
}

static void *read_file(const char *path, size_t *size)
{
    FILE *f;
    long n;
    void *buffer;

    f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    n = ftell(f);
    if (n <= 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    buffer = malloc((size_t)n);
    if (!buffer) {
        fclose(f);
        return NULL;
    }
    if (fread(buffer, 1, (size_t)n, f) != (size_t)n) {
        fclose(f);
        free(buffer);
        return NULL;
    }
    fclose(f);
    *size = (size_t)n;
    return buffer;
}

static const char *board_text(enum device_board board)
{
    switch (board) {
    case DEVICE_BOARD_UNKNOWN:
        return "UNKNOWN";
    case DEVICE_BOARD_TB322FC:
        return "TB322FC";
    case DEVICE_BOARD_TB323FU:
        return "TB323FU";
    case DEVICE_BOARD_TB320FC:
        return "TB320FC";
    default:
        return "out-of-range";
    }
}

static const char *soc_text(enum device_soc soc)
{
    switch (soc) {
    case DEVICE_SOC_UNKNOWN:
        return "UNKNOWN";
    case DEVICE_SOC_SM8475:
        return "SM8475";
    case DEVICE_SOC_SM8750:
        return "SM8750";
    case DEVICE_SOC_SM8850:
        return "SM8850";
    default:
        return "out-of-range";
    }
}

static void dump_root(const void *fdt)
{
    const char *model = fdt_getprop(fdt, 0, "model", NULL);
    const char *compat = fdt_getprop(fdt, 0, "compatible", NULL);
    int count = fdt_stringlist_count(fdt, 0, "compatible");
    int i;

    printf("root model       : %s\n", model ? model : "(absent)");
    printf("root compatible  : %d entries\n", count);
    if (compat) {
        for (i = 0; i < count; ++i) {
            const char *entry = fdt_stringlist_get(fdt, 0, "compatible", i, NULL);

            if (entry)
                printf("                   - %s\n", entry);
        }
    }
}

int main(int argc, char **argv)
{
    const char *base_path = argc > 1 ? argv[1] : "vb_02.dtb";
    const char *overlay_path = argc > 2 ? argv[2] : NULL;
    void *base;
    void *work;
    size_t base_size = 0;
    size_t overlay_size = 0;
    struct device_info info;
    struct kshim_resources resources;
    struct CrIo io;
    kshim_framebuffer_config_t framebuffer;
    kshim_mmu_region_t mmio;
    struct dt_range reservation;
    const struct kshim_splash_trace *trace;
    char report[512];
    QcomKeyDescriptor keys[QCOM_KEYS_MAX];
    size_t key_count = 0;
    bool no_map = false;
    int rc;

    base = read_file(base_path, &base_size);
    if (!base)
        return 2;
    work = malloc(WORK_SIZE);
    if (!work) {
        free(base);
        return 2;
    }
    if (dt_validate(base, base_size)) {
        fprintf(stderr, "base blob rejected by dt_validate\n");
        free(base);
        free(work);
        return 2;
    }
    rc = fdt_open_into(base, work, (int)WORK_SIZE);
    free(base);
    if (rc) {
        fprintf(stderr, "fdt_open_into: %s\n", fdt_strerror(rc));
        free(work);
        return 2;
    }
    if (overlay_path) {
        void *overlay_raw;
        void *overlay_work;
        size_t overlay_capacity;
        int applied;

        overlay_raw = read_file(overlay_path, &overlay_size);
        if (!overlay_raw) {
            free(work);
            return 2;
        }
        if (dt_validate(overlay_raw, overlay_size)) {
            fprintf(stderr, "overlay blob rejected by dt_validate\n");
            free(overlay_raw);
            free(work);
            return 2;
        }
        overlay_capacity = overlay_size + 262144u;
        overlay_work = malloc(overlay_capacity);
        if (!overlay_work) {
            free(overlay_raw);
            free(work);
            return 2;
        }
        rc = fdt_open_into(overlay_raw, overlay_work, (int)overlay_capacity);
        free(overlay_raw);
        if (rc) {
            fprintf(stderr, "fdt_open_into(overlay): %s\n", fdt_strerror(rc));
            free(overlay_work);
            free(work);
            return 2;
        }
        applied = fdt_overlay_apply(work, overlay_work);
        free(overlay_work);
        if (applied) {
            fprintf(stderr, "fdt_overlay_apply(%s): %s\n", overlay_path,
                    fdt_strerror(applied));
            free(work);
            return 2;
        }
        printf("overlay          : %s applied, totalsize %d\n", overlay_path,
               fdt_totalsize(work));
    }
    if (dt_validate(work, WORK_SIZE)) {
        fprintf(stderr, "merged blob rejected by dt_validate\n");
        free(work);
        return 2;
    }

    printf("== device tree ==\n");
    dump_root(work);

    printf("== device_info ==\n");
    device_info_read(work, &info);
    printf("board            : %s\nsoc              : %s\n",
           board_text(info.board), soc_text(info.soc));
    printf("ram reported     : %llu bytes (known=%d)\n",
           (unsigned long long)info.dt_reported_ram_bytes, info.ram_known ? 1 : 0);

    printf("== splash reservation ==\n");
    memset(&reservation, 0, sizeof(reservation));
    rc = kshim_dt_splash_reservation(work, &reservation, &no_map);
    printf("rc               : %d  base=0x%llx size=0x%llx no-map=%d\n", rc,
           (unsigned long long)reservation.base,
           (unsigned long long)reservation.size, no_map ? 1 : 0);

    printf("== splash (DT gates + stub MMIO) ==\n");
    memset(&io, 0, sizeof(io));
    io.context = NULL;
    io.read32 = probe_read32;
    io.write32 = probe_write32;
    memset(&framebuffer, 0, sizeof(framebuffer));
    memset(&mmio, 0, sizeof(mmio));
    rc = kshim_dt_splash(work, &io, &framebuffer, &mmio);
    trace = kshim_splash_trace_get();
    printf("rc               : %d\n", rc);
    if (trace) {
        printf("dt_stage         : %u\n", trace->dt_stage);
        printf("root compat cnt  : %d  sunp=%d\n", trace->root_compatible_count,
               trace->root_has_sunp ? 1 : 0);
        printf("mmio reads       : %u  last_offset=0x%x\n", trace->count,
               trace->last_offset);
        printf("values           : %u %u %u %u %u\n", trace->values[0],
               trace->values[1], trace->values[2], trace->values[3],
               trace->values[4]);
        memset(report, 0, sizeof(report));
        if (kshim_splash_trace_report(trace, rc, report, sizeof(report)) > 0)
            printf("report           : %s\n", report);
    }
    printf("stub mmio reads  : %lu\n", g_mmio_reads);
    printf("framebuffer      : addr=0x%lx %ux%u stride=%u bpp=%u size=%zu\n",
           (unsigned long)framebuffer.render_address, framebuffer.width,
           framebuffer.height, framebuffer.stride, framebuffer.bpp,
           framebuffer.buffer_size);
    printf("mmio region      : base=0x%llx size=0x%llx\n",
           (unsigned long long)mmio.base, (unsigned long long)mmio.size);

    printf("== spmi ==\n");
    memset(&resources, 0, sizeof(resources));
    resources.fdt = work;
    rc = kshim_dt_spmi(work, &resources);
    printf("rc               : %d  count=%u status=%d\n", rc,
           resources.spmi_count, resources.spmi_status);

    printf("== keys ==\n");
    rc = QcomKeysBuildFromDeviceTree(work, keys, QCOM_KEYS_MAX, &key_count);
    printf("rc               : %d  count=%zu\n", rc, key_count);
    for (size_t i = 0; i < key_count && i < QCOM_KEYS_MAX; ++i)
        printf("  key %zu          : code=%u source=%d base=0x%llx off=0x%x mask=0x%x\n",
               i, keys[i].Code, (int)keys[i].Source,
               (unsigned long long)keys[i].Base, keys[i].RegisterOffset,
               keys[i].Mask);

    free(work);
    return 0;
}
