import io

K = "/tmp/y700/kbuild/asphalt-linux"


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="").write(s)


# ---------------- drivers/video/fbdev/y700fb.c ----------------
p = K + "/drivers/video/fbdev/y700fb.c"
s = rd(p)
if "y700fb_takeover" not in s:
    old_inc = "#include <linux/earlycon_simplefb.h>\n#include <linux/fb.h>\n"
    new_inc = "#include <linux/earlycon_simplefb.h>\n#include <linux/fb.h>\n#include <linux/module.h>\n"
    assert s.count(old_inc) == 1, "fb includes"
    s = s.replace(old_inc, new_inc)

    old_par = "struct y700fb_par {\n"
    new_par = (
        "/*\n"
        " * CONFIG_FRAMEBUFFER_CONSOLE is off on this board, so handing the text\n"
        " * console to fbcon at late_initcall() leaves the panel frozen at whatever\n"
        " * the earlycon last drew (A71/A72: nothing after 2.2 s).  Keep the earlycon\n"
        " * drawing unless someone explicitly asks for the handover.\n"
        " */\n"
        "static bool y700fb_takeover;\n"
        "module_param(y700fb_takeover, bool, 0444);\n"
        "MODULE_PARM_DESC(y700fb_takeover, \"stop the simplefb earlycon and let fbcon take the panel; pointless while CONFIG_FRAMEBUFFER_CONSOLE is off\");\n"
        "\n"
        "struct y700fb_par {\n"
    )
    assert s.count(old_par) == 1, "fb par"
    s = s.replace(old_par, new_par, 1)

    old_off = (
        "\tsimplefb_console_off();\n"
        "\tpar->taken_over = true;\n"
    )
    new_off = (
        "\tif (y700fb_takeover) {\n"
        "\t\tsimplefb_console_off();\n"
        "\t\tpar->taken_over = true;\n"
        "\t}\n"
        "\tpr_emerg(\"Y700-FB console kept on the simplefb earlycon takeover=%d fbcon=%s\\n\",\n"
        "\t\t y700fb_takeover, IS_ENABLED(CONFIG_FRAMEBUFFER_CONSOLE) ? \"built\" : \"absent\");\n"
    )
    assert s.count(old_off) == 1, "fb console_off"
    s = s.replace(old_off, new_off)
    wr(p, s)
    print("FB_PATCHED")
else:
    print("FB_ALREADY")

# ------------- drivers/input/touchscreen/novatek-nt36523n-spi.c -------------
p = K + "/drivers/input/touchscreen/novatek-nt36523n-spi.c"
s = rd(p)
if "nvt_stage" not in s:
    old_head = "static int nvt_nt36523n_run_test(struct nvt_nt36523n *nvt)\n"
    new_head = (
        "/*\n"
        " * How far the bring-up may take the controller in one probe.  Driving the\n"
        " * NT36523N reset line, the first SPI transaction and the firmware download are\n"
        " * three different things to a board that has never talked to this chip, and A71\n"
        " * and A72 both ended in a reset about a second after the bind without leaving a\n"
        " * single line saying which one it was.  Writable from userspace\n"
        " * (/sys/module/<drv>/parameters/nvt_stage) so one boot can walk the stages.\n"
        " *   0 no SPI, no reset line   1 reset line + engine reset only\n"
        " *   2 + trim ID read          3 + firmware download and input registration\n"
        " */\n"
        "static int nvt_stage = 3;\n"
        "module_param(nvt_stage, int, 0644);\n"
        "MODULE_PARM_DESC(nvt_stage, \"touch bring-up stage: 0 nothing, 1 reset line, 2 trim ID, 3 download firmware (default 3)\");\n"
        "\n"
        "static int nvt_nt36523n_run_test(struct nvt_nt36523n *nvt)\n"
    )
    assert s.count(old_head) == 1, "touch run_test head"
    s = s.replace(old_head, new_head, 1)

    old_a = (
        "\t/* The downstream host-download sequence performs this while reset is low. */\n"
        "\tusleep_range(1000, 2000);\n"
        "\terror = nvt_write_addr(nvt, NVT_ENG_RESET_ADDR, 0x5a);\n"
    )
    new_a = (
        "\tif (nvt_stage < 1) {\n"
        "\t\tdev_info(dev, \"NVT-STAGE 0 stop before any SPI or reset line\\n\");\n"
        "\t\treturn -EACCES;\n"
        "\t}\n"
        "\t/* The downstream host-download sequence performs this while reset is low. */\n"
        "\tusleep_range(1000, 2000);\n"
        "\terror = nvt_write_addr(nvt, NVT_ENG_RESET_ADDR, 0x5a);\n"
    )
    assert s.count(old_a) == 1, "touch stage1"
    s = s.replace(old_a, new_a)

    old_b = (
        "\tusleep_range(10000, 11000);\n"
        "\n"
        "\tfor (retry = 0; retry < 3; retry++) {\n"
    )
    new_b = (
        "\tusleep_range(10000, 11000);\n"
        "\tdev_info(dev, \"NVT-STAGE 1 reset line released, engine reset written\\n\");\n"
        "\tif (nvt_stage < 2) {\n"
        "\t\terror = -EACCES;\n"
        "\t\tgoto out_assert_reset;\n"
        "\t}\n"
        "\n"
        "\tfor (retry = 0; retry < 3; retry++) {\n"
    )
    assert s.count(old_b) == 1, "touch stage2"
    s = s.replace(old_b, new_b)

    old_c = (
        "\telse\n"
        "\t\terror = nvt_test_firmware_download(nvt);\n"
    )
    new_c = (
        "\telse if (nvt_stage < 3) {\n"
        "\t\tdev_info(dev, \"NVT-STAGE 2 trim ID %*ph, no firmware download\\n\",\n"
        "\t\t\t NVT_ID_LEN, id);\n"
        "\t\terror = -EACCES;\n"
        "\t} else\n"
        "\t\terror = nvt_test_firmware_download(nvt);\n"
    )
    assert s.count(old_c) == 1, "touch stage3"
    s = s.replace(old_c, new_c)
    wr(p, s)
    print("TOUCH_PATCHED")
else:
    print("TOUCH_ALREADY")
