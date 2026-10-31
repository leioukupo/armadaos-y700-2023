import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0224-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch"
s = open(p, encoding="utf-8", errors="replace").read().replace("\r\n","\n")
lines = s.splitlines()
# includes
for i, l in enumerate(lines):
    if l.startswith("+") and ("#include" in l or "module.h" in l or "drm_mipi" in l or "mipi_dsi.h" in l):
        print(i+1, l[:120])
print("--- other mipi_dsi_ API usage (non dual) ---")
apis = {}
for l in lines:
    if l.startswith("+"):
        for m in re.findall(r'mipi_dsi_\w+', l):
            apis[m] = apis.get(m, 0) + 1
for k, v in sorted(apis.items()):
    print(f"{k}: {v}")
