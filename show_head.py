s = open(r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475.dtsi", encoding="utf-8", newline="").read().replace("\r\n","")
lines = s.splitlines()
for i in range(0, 22):
    print(i+1, repr(lines[i]))
