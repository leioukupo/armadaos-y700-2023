import sys
p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475.dtsi"
s = open(p, encoding="utf-8", newline="").read().replace("\r\n","\n")
lines = s.splitlines(True)
# line 4 (idx 3): " */" -> " *"  ; line 5 (idx 4): "/*" -> " *"  ; line 20 (idx 19): "" -> " */\n"
assert lines[3] == " */\n", repr(lines[3])
assert lines[4] == "/*\n", repr(lines[4])
assert lines[19] == "\n", repr(lines[19])
lines[3] = " *\n"
lines[4] = " *\n"
lines[19] = " */\n"
open(p, "w", encoding="utf-8", newline="").write("".join(lines))
print("fixed head:")
for i in range(0, 22):
    print(i+1, repr(lines[i].rstrip()))
