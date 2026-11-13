#!/usr/bin/env python3
# Y700-A147: refuse suspend on this tablet.  s2idle kills the ADSP, which takes
# the PMIC GLINK battery gauge (and AudioReach, and Wi-Fi) down with it.
import sys

MARK = "Y700-A147"
ANCHOR = "# ---- end A142 unconditional power install ----"
BLOCK = """# ---- A147 no suspend on this tablet ----
# s2idle is not usable here.  A suspend/resume cycle kills the ADSP: the resume
# logs "qcom_q6v5_pas ... fatal error received: sleep_stats" and PMIC GLINK then
# answers nothing, so every power_supply value goes empty for a few seconds.
# upower shows an empty cell, Plasma pops "battery is very low, the system will
# sleep in 60 seconds" and suspends again - a loop.  Nothing on this board has a
# validated suspend path (remoteproc, Adreno GMU, ath11k, the panel), so the
# sleep operation is refused instead of attempted.
mkdir -p "$R/etc/systemd/sleep.conf.d" 2>/dev/null
cat > "$R/etc/systemd/sleep.conf.d/10-y700-no-suspend.conf" <<'SLEEP147'
# Written by the Y700 A-series initramfs patch (A147).
# s2idle kills the ADSP: the PMIC GLINK battery gauge, AudioReach and Wi-Fi all
# live on it, so a suspend/resume cycle leaves the battery reading empty and the
# desktop believes the cell is flat.  Suspend is therefore refused.
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
SLEEP147
echo "Y700-A147 sleep-off written=$(stat -c %s "$R/etc/systemd/sleep.conf.d/10-y700-no-suspend.conf" 2>/dev/null) up=$(cut -d . -f 1 /proc/uptime)" > /dev/kmsg 2>/dev/null
# ---- end A147 no suspend ----
"""


def main():
    path = sys.argv[1]
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    if MARK in src:
        print("A147_ALREADY_APPLIED")
        return 0
    if src.count(ANCHOR) != 1:
        print("A147_ANCHOR_NOT_UNIQUE count=%d" % src.count(ANCHOR))
        return 1
    src = src.replace(ANCHOR, BLOCK + ANCHOR, 1)
    open(path, "w", encoding="utf-8", newline="\n").write(src)
    print("A147_PATCH_OK marks=%d bytes=%d" % (src.count(MARK), len(src)))
    return 0


if __name__ == "__main__":
    sys.exit(main())