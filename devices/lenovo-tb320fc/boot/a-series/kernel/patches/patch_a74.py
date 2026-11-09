import io

K = "/tmp/y700/kbuild/asphalt-linux"


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="").write(s)


# ---------------- drivers/spi/spi-geni-qcom.c ----------------
# A73 walked the touch stages and died inside the firmware download, on the
# first big SPI write (NVT_FW_TRANSFER_MAX = 63 KiB).  A transfer bigger than
# the SE FIFO makes geni_can_dma() say yes, the core maps it, and
# spi_geni_transfer_one() then picks GENI_SE_DMA for it; the small reads that
# stage 1 and 2 used stayed in GENI_SE_FIFO and survived.  The SE DMA path on
# this QUP has never worked under the ABL clock/power state this kernel keeps
# (clk_ignore_unused/pd_ignore_unused), and A47 (bus stall) and A65 (MDSS read
# hang) were the same class of failure.  force_pio turns that into a runtime
# switch: with can_dma() answering no, nothing gets mapped, tx_sg.nents stays
# 0 and the master stays on PIO.
p = K + "/drivers/spi/spi-geni-qcom.c"
s = rd(p)
if "force_pio" not in s:
    old_inc = "#include <linux/spinlock.h>\n"
    new_inc = (
        "#include <linux/spinlock.h>\n"
        "\n"
        "/*\n"
        " * Y700 bring-up switch.  Answer no to the core's can_dma() question for\n"
        " * every transfer, so buffers are never mapped, xfer->tx_sg.nents stays 0 and\n"
        " * transfer_one() keeps the SE in GENI_SE_FIFO (PIO) even for a 63 KiB write.\n"
        " * Writable from userspace (force_pio, 0644) so one boot can compare the\n"
        " * two paths without reflashing.\n"
        " */\n"
        "static bool force_pio;\n"
        "module_param(force_pio, bool, 0644);\n"
        "MODULE_PARM_DESC(force_pio, \"never use SE DMA for SPI transfers, always PIO through the FIFO\");\n"
    )
    assert s.count(old_inc) == 1, "spi includes"
    s = s.replace(old_inc, new_inc, 1)

    old_dma = (
        "\tlen = get_xfer_len_in_words(xfer, mas);\n"
        "\tfifo_size = mas->tx_fifo_depth * mas->fifo_width_bits / xfer->bits_per_word;\n"
    )
    new_dma = (
        "\tif (force_pio)\n"
        "\t\treturn false;\n"
        "\n"
        "\tlen = get_xfer_len_in_words(xfer, mas);\n"
        "\tfifo_size = mas->tx_fifo_depth * mas->fifo_width_bits / xfer->bits_per_word;\n"
    )
    assert s.count(old_dma) == 1, "spi can_dma"
    s = s.replace(old_dma, new_dma, 1)

    # Name the mode out loud, on the panel, for the transfers that matter.
    old_mode = (
        "\t} else\n"
        "\t\tmas->cur_xfer_mode = GENI_SE_DMA;\n"
        "\tgeni_se_select_mode(se, mas->cur_xfer_mode);\n"
    )
    new_mode = (
        "\t} else\n"
        "\t\tmas->cur_xfer_mode = GENI_SE_DMA;\n"
        "\tif (xfer->len > 1024 && y700_mode_log < 8) {\n"
        "\t\ty700_mode_log++;\n"
        "\t\tdev_info(mas->dev,\n"
        "\t\t\t \"Y700-GENI xfer %u B mode=%u fifo_bytes=%u force_pio=%d\\n\",\n"
        "\t\t\t xfer->len, mas->cur_xfer_mode,\n"
        "\t\t\t mas->tx_fifo_depth * mas->fifo_width_bits / 8, force_pio);\n"
        "\t}\n"
        "\tgeni_se_select_mode(se, mas->cur_xfer_mode);\n"
    )
    assert s.count(old_mode) == 1, "spi mode select"
    s = s.replace(old_mode, new_mode, 1)

    old_head = "static int setup_se_xfer(struct spi_transfer *xfer,\n"
    new_head = "static int y700_mode_log;\n\nstatic int setup_se_xfer(struct spi_transfer *xfer,\n"
    assert s.count(old_head) == 1, "spi setup_se_xfer head"
    s = s.replace(old_head, new_head, 1)
    wr(p, s)
    print("SPI_PATCHED")
else:
    print("SPI_ALREADY")

# ------------- drivers/input/touchscreen/novatek-nt36523n-spi.c -------------
p = K + "/drivers/input/touchscreen/novatek-nt36523n-spi.c"
s = rd(p)
if "nvt_fw_chunk" not in s:
    old_head = "static int nvt_write_firmware(struct nvt_nt36523n *nvt,\n"
    new_head = (
        "/*\n"
        " * The A73 firmware download reached the first host->SRAM write and the board\n"
        " * reset without another line, which is the one action stage 1 and stage 2 did\n"
        " * not perform: a transfer larger than the QUP FIFO, and therefore an SE DMA\n"
        " * transfer.  Two knobs so the same boot can cut that transfer up (chunk) or\n"
        " * stop it part-way (bytes) and say which of the two killed it.  0 is the\n"
        " * vendor behaviour in both cases.\n"
        " */\n"
        "static int nvt_fw_chunk;\n"
        "module_param(nvt_fw_chunk, int, 0644);\n"
        "MODULE_PARM_DESC(nvt_fw_chunk, \"firmware payload bytes per SPI write (0 = vendor 63 KiB)\");\n"
        "\n"
        "static int nvt_fw_bytes;\n"
        "module_param(nvt_fw_bytes, int, 0644);\n"
        "MODULE_PARM_DESC(nvt_fw_bytes, \"stop the download after this many payload bytes (0 = whole image)\");\n"
        "\n"
        "static int nvt_write_firmware(struct nvt_nt36523n *nvt,\n"
    )
    assert s.count(old_head) == 1, "touch write_firmware head"
    s = s.replace(old_head, new_head, 1)

    old_pl = (
        "\tmax_payload = min_t(size_t, NVT_FW_TRANSFER_MAX, max_transfer - 1);\n"
        "\tbuf = kmalloc(max_payload + 1, GFP_KERNEL);\n"
        "\tif (!buf)\n"
        "\t\treturn -ENOMEM;\n"
    )
    new_pl = (
        "\tmax_payload = min_t(size_t, NVT_FW_TRANSFER_MAX, max_transfer - 1);\n"
        "\tif (nvt_fw_chunk > 0 && (size_t)nvt_fw_chunk < max_payload)\n"
        "\t\tmax_payload = (size_t)nvt_fw_chunk;\n"
        "\tbuf = kmalloc(max_payload + 1, GFP_KERNEL);\n"
        "\tif (!buf)\n"
        "\t\treturn -ENOMEM;\n"
        "\n"
        "\tdev_info(&spi->dev, \"NVT-FW begin chunk=%zu fw=%zu limit=%d\\n\",\n"
        "\t\t max_payload, fw->size, nvt_fw_bytes);\n"
    )
    assert s.count(old_pl) == 1, "touch payload"
    s = s.replace(old_pl, new_pl, 1)

    old_loop = (
        "\t\tsize_t remaining;\n"
        "\t\tu32 bin_addr;\n"
        "\t\tu32 sram_addr;\n"
    )
    new_loop = (
        "\t\tsize_t remaining;\n"
        "\t\tu32 bin_addr;\n"
        "\t\tu32 sram_addr;\n"
        "\t\tunsigned int part_no = i;\n"
    )
    assert s.count(old_loop) == 1, "touch partition locals"
    s = s.replace(old_loop, new_loop, 1)

    old_adv = (
        "\t\t\tremaining -= len;\n"
        "\t\t\tbin_addr += len;\n"
        "\t\t\tsram_addr += len;\n"
        "\t\t}\n"
    )
    new_adv = (
        "\t\t\tremaining -= len;\n"
        "\t\t\tbin_addr += len;\n"
        "\t\t\tsram_addr += len;\n"
        "\t\t\tsent += len;\n"
        "\t\t\tchunks++;\n"
        "\t\t\tif (chunks <= 3 || (chunks % 64) == 0)\n"
        "\t\t\t\tdev_info(&spi->dev,\n"
        "\t\t\t\t\t \"NVT-FW part%u chunk %u sent, %zu bytes so far\\n\",\n"
        "\t\t\t\t\t part_no, chunks, sent);\n"
        "\t\t\tif (nvt_fw_bytes > 0 && sent >= (size_t)nvt_fw_bytes) {\n"
        "\t\t\t\tdev_info(&spi->dev,\n"
        "\t\t\t\t\t \"NVT-FW stopped at the %d byte limit (%u chunks)\\n\",\n"
        "\t\t\t\t\t nvt_fw_bytes, chunks);\n"
        "\t\t\t\terror = -EACCES;\n"
        "\t\t\t\tgoto out_free;\n"
        "\t\t\t}\n"
        "\t\t}\n"
        "\t\tdev_info(&spi->dev, \"NVT-FW part%u written (%u chunks, %zu bytes)\\n\",\n"
        "\t\t\t part_no, chunks, sent);\n"
    )
    assert s.count(old_adv) == 1, "touch advance"
    s = s.replace(old_adv, new_adv, 1)

    old_decl = (
        "\tsize_t max_payload;\n"
        "\tu8 *buf;\n"
        "\tu32 i;\n"
        "\tint error = 0;\n"
    )
    new_decl = (
        "\tsize_t max_payload;\n"
        "\tsize_t sent = 0;\n"
        "\tunsigned int chunks = 0;\n"
        "\tu8 *buf;\n"
        "\tu32 i;\n"
        "\tint error = 0;\n"
    )
    assert s.count(old_decl) == 1, "touch locals"
    s = s.replace(old_decl, new_decl, 1)

    old_free = (
        "out_free:\n"
        "\tkfree(buf);\n"
        "\treturn error;\n"
    )
    new_free = (
        "out_free:\n"
        "\tdev_info(&spi->dev, \"NVT-FW end %u chunks, %zu bytes, error=%d\\n\",\n"
        "\t\t chunks, sent, error);\n"
        "\tkfree(buf);\n"
        "\treturn error;\n"
    )
    assert s.count(old_free) == 1, "touch out_free"
    s = s.replace(old_free, new_free, 1)
    wr(p, s)
    print("TOUCH_PATCHED")
else:
    print("TOUCH_ALREADY")
