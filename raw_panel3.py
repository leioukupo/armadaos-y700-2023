p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0224-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch"
s = open(p, encoding="utf-8", errors="replace").read().replace("\r\n","\n")
lines = s.splitlines()
for i in range(0, 42):
    print(i+1, lines[i][:140])
print("...")
# find include lines anywhere
for i, l in enumerate(lines):
    if "include" in l and i < 60:
        print("INC@", i+1, l[:140])
