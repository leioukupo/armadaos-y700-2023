import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0225-input-touchscreen-import-Novatek-NVT36xxx-host-download-SPI-driver-for-Lenovo-TB320FC.patch"
s = open(p, encoding="utf-8", errors="replace").read().replace("\r\n","\n")
lines = s.splitlines()
# which new files, and their vendor includes
cur = None
inc_by_file = {}
for l in lines:
    if l.startswith("diff --git"):
        cur = l.split(" b/")[-1]
        inc_by_file[cur] = []
    elif l.startswith("+") and "#include" in l and cur:
        inc_by_file[cur].append(l)
for f, incs in inc_by_file.items():
    vend = [i for i in incs if any(v in i for v in ("touch_common", "of_gpio", "msm_drm", "earlysuspend", "panel_event"))]
    if vend:
        print(f)
        for v in vend:
            print("   ", v[:120])
