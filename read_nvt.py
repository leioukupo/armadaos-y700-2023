import re, glob
files = glob.glob(r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0225*")
print(files)
s = open(files[0], encoding="utf-8", errors="replace").read().replace("\r\n","\n")
lines = s.splitlines()
print("patch lines:", len(lines))
for i in range(0, 40):
    print(i+1, lines[i][:140])
