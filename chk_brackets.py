import sys
for name, p in [
    ("sm8475.dtsi", r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475.dtsi"),
    ("sm8475-lenovo-tb320fc.dts", r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475-lenovo-tb320fc.dts"),
]:
    src = open(p, encoding="utf-8", newline="").read().replace("\r\n","")
    i = 0; n = len(src); line = 1
    in_str = in_line_c = in_block_c = False
    in_bytes = 0
    last_open = None
    while i < n:
        c = src[i]
        if c == "\n": line += 1; i += 1; continue
        if in_str:
            if c == "\\": i += 2; continue
            if c == '"': in_str = False
            i += 1; continue
        if in_block_c:
            if c == "*" and i+1 < n and src[i+1] == "/": in_block_c = False; i += 2; continue
            i += 1; continue
        if in_line_c: i += 1; continue
        if c == "/" and i+1 < n:
            if src[i+1] == "*": in_block_c = True; i += 2; continue
            if src[i+1] == "/": in_line_c = True; i += 2; continue
        if c == '"': in_str = True; i += 1; continue
        if c == "[":
            in_bytes += 1
            if in_bytes > 1:
                print(name, "line", line, "NESTED [:", src[max(0,i-60):i+60].replace("\n"," ")[:120])
            last_open = line
        elif c == "]":
            in_bytes -= 1
            if in_bytes < 0:
                print(name, "line", line, "EXTRA ]")
                in_bytes = 0
        i += 1
    print(name, "final [ balance:", in_bytes, "last open line:", last_open)
