import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0225-input-touchscreen-import-Novatek-NVT36xxx-host-download-SPI-driver-for-Lenovo-TB320FC.patch"
s = open(p, encoding="utf-8", errors="replace").read().replace("\r\n","\n")
lines = s.splitlines()
for i, l in enumerate(lines):
    if "earlysuspend.h" in l and l.startswith("+"):
        print("ctx around line", i+1, ":")
        for j in range(max(0,i-8), min(len(lines), i+4)):
            print(j+1, lines[j][:120])
        break
