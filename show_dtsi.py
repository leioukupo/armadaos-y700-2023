s = open(r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475.dtsi", encoding="utf-8", newline="").read().replace("\r\n","")
lines = s.splitlines()
print("=== 40-62 ===")
for i in range(39, 62):
    print(i+1, repr(lines[i][:110]))
print("=== 505-520 ===")
for i in range(504, 520):
    print(i+1, repr(lines[i][:110]))
