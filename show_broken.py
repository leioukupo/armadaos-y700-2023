import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0224-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch"
s = open(p, encoding="utf-8", newline="").read().replace("\r\n","\n")
lines = s.splitlines()
bad = [(i+1, l) for i, l in enumerate(lines) if "dual_dcs_write_seq_multi" in l and l.startswith("+") and not l.rstrip().endswith(");")]
for ln, l in bad[:12]:
    print(ln, repr(l[:130]))
print("...total:", len(bad))
