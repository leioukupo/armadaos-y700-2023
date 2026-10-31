import re
for name, p in [
    ("sm8475.dtsi", r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475.dtsi"),
    ("tb320fc.dts", r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\dts\sm8475-lenovo-tb320fc.dts"),
]:
    s = open(p, encoding="utf-8", newline="").read().replace("\r\n","")
    hits = [(i+1, l.strip()[:100]) for i, l in enumerate(s.splitlines()) if re.match(r'\s*#\s*(if|ifdef|ifndef|else|endif|include|define)', l)]
    print(name, len(hits), "pp lines")
    for h in hits[:20]:
        print("  ", h)
