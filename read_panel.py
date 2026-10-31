import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0224-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch"
s = open(p, encoding="utf-8", errors="replace").read().replace("\r\n","\n")
lines = s.splitlines()
print("patch lines:", len(lines))
# find added lines using the dual macro
for i, l in enumerate(lines):
    if l.startswith("+") and ("dual" in l or "include" in l or "mipi_dsi" in l):
        print(i+1, l[:150])
