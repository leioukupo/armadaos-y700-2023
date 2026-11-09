#!/usr/bin/env python3
# A81 = A80 + the panel handed to a real console.
#
# The whole A-series has been reading the device through the simplefb earlycon,
# which only exists because nothing else drew on the glass: ABL streams the
# framebuffer at 0xb8000000, y700fb (CONFIG_FB_Y700) registers an fbdev over it,
# and CONFIG_FRAMEBUFFER_CONSOLE was off, so y700fb_takeover had to stay off too
# or the panel would freeze (A73).  A81 builds fbcon in and defaults the handover
# to on, so the console itself is the display: boot log, getty, and later the
# ArmadaOS UI all land on the panel instead of on a serial-less earlycon.
import sys

P = "drivers/video/fbdev/y700fb.c"
OLD = "static bool y700fb_takeover;\n"
NEW = ("/* Hand the panel to fbcon by default now that CONFIG_FRAMEBUFFER_CONSOLE is\n"
       " * built in; the earlycon stops drawing at register_framebuffer() either way. */\n"
       "static bool y700fb_takeover = true;\n")

with open(P, encoding="utf-8") as handle:
    src = handle.read()

if "static bool y700fb_takeover = true;" in src:
    print("A81_PATCH_ALREADY_APPLIED")
elif OLD in src:
    src = src.replace(OLD, NEW, 1)
    with open(P, "w", encoding="utf-8") as handle:
        handle.write(src)
    print("A81_PATCH_APPLIED takeover-default=true")
else:
    print("A81_PATCH_ANCHOR_MISSING")
    sys.exit(1)

with open(P, encoding="utf-8") as handle:
    src = handle.read()
for marker in ("static bool y700fb_takeover = true;",
               "simplefb_console_off();",
               "register_framebuffer(info);"):
    if marker not in src:
        print("A81_POSTCOND_MISSING " + marker)
        sys.exit(1)
print("A81_PATCH_OK")
