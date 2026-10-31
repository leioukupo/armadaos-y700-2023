import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0224-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch"
s = open(p, encoding="utf-8", newline="").read().replace("\r\n","\n")
lines = s.splitlines()
for ln in (149, 159, 435):
    i = ln - 1
    print("---", ln, "---")
    for j in range(i, i+3):
        print(j+1, repr(lines[j][:110]))
