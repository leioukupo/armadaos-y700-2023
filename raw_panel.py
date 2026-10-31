import re
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0224-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch"
b = open(p, "rb").read()
print("bytes:", len(b))
s = b.decode("utf-8", errors="replace").replace("\r\n","\n")
lines = s.splitlines()
# print raw of the dual macro lines (first 6) with repr
cnt = 0
for i, l in enumerate(lines):
    if "dual_dcs_write_seq_multi" in l and l.startswith("+"):
        print(i+1, repr(l))
        cnt += 1
        if cnt >= 6: break
# count total
tot = sum(1 for l in lines if "dual_dcs_write_seq_multi" in l and l.startswith("+"))
print("total dual lines:", tot)
# check how many have closing paren
good = sum(1 for l in lines if "dual_dcs_write_seq_multi" in l and l.startswith("+") and l.rstrip().endswith(");"))
print("ending with ');':", good)
