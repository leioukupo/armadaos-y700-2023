import os, re
REPO_DTS = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts"
K = r"C:\Users\Administrator\y700-2nd\linux-src\linux-7.2.6"
def strip_comments(src):
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if c == "/" and i+1 < n:
            if src[i+1] == "*":
                j = src.find("*/", i+2)
                i = n if j < 0 else j+2
                continue
            if src[i+1] == "/":
                j = src.find("\n", i)
                i = n if j < 0 else j
                continue
        out.append(c); i += 1
    return "".join(out)
def bracket_balance(src):
    s = strip_comments(src)
    # remove strings
    s2 = re.sub(r'"([^"\\]|\\.)*"', '""', s)
    bal = 0; lines = s2.splitlines()
    pos = 0
    for ln in lines:
        pos += 1
        for ch in ln:
            if ch == "[": bal += 1
            elif ch == "]":
                if bal < 0: return -1, pos
                bal -= 1
    return bal, pos
# includes of our dtsi (in order)
dtsi = open(os.path.join(REPO_DTS, "sm8475.dtsi"), encoding="utf-8", newline="").read().replace("\r\n","")
incs = re.findall(r'#include\s*[<"]([^">]+)[">]', dtsi)
print("includes:", incs)
for inc in incs:
    # resolve: board dts dir, kernel include dir
    cands = [
        os.path.join(REPO_DTS, inc),
        os.path.join(K, "arch/arm64/boot/dts/qcom", inc),
        os.path.join(K, "include", inc),
        os.path.join(K, "arch/arm64/boot/dts/qcom", os.path.dirname(inc), os.path.basename(inc)),
    ]
    found = None
    for c in cands:
        if os.path.isfile(c): found = c; break
    if not found:
        print("NOT FOUND:", inc); continue
    src = open(found, encoding="utf-8", errors="replace").read().replace("\r\n","")
    bal, _ = bracket_balance(src)
    print(f"{inc:60s} bal={bal}")
