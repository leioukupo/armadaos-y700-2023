import sys
src = open(r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475.dtsi", encoding="utf-8", newline="").read().replace("\r\n","")
i = 0
n = len(src)
line = 1
in_str = False
in_line_c = False
in_block_c = False
depth = 0
stack = []
events = []
while i < n:
    c = src[i]
    if c == "\n":
        line += 1
        i += 1
        continue
    if in_str:
        if c == "\\": i += 2; continue
        if c == '"': in_str = False
        i += 1
        continue
    if in_block_c:
        if c == "*" and i+1 < n and src[i+1] == "/":
            in_block_c = False; i += 2; continue
        i += 1
        continue
    if in_line_c:
        i += 1
        continue
    if c == "/" and i+1 < n:
        if src[i+1] == "*":
            in_block_c = True; i += 2; continue
        if src[i+1] == "/":
            in_line_c = True; i += 2; continue
    if c == '"':
        in_str = True; i += 1; continue
    if c in "{(<":
        stack.append((c, line)); depth += 1
    elif c in "})>":
        if not stack:
            events.append(("UNBAL-CLOSE", c, line)); depth = 0
        else:
            o, ol = stack.pop()
            if (c, o) not in (("{","}"), (")",")"), (">","<")):
                events.append(("MISMATCH", f"{o}@{ol} vs {c}@{line}", line))
            depth -= 1
    i += 1
events = [e for e in events if e[0] != "MISMATCH" or True]
print("events:", events[:30])
print("final depth:", depth, "stack:", [(c,l) for c,l in stack[-10:]])
if stack:
    lines = src.splitlines()
    ch, l = stack[-1]
    for x in range(max(0,l-6), min(len(lines), l+3)):
        print(x+1, lines[x][:130])
