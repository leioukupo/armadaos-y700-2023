p = r"C:\Users\Administrator\armadaos-y700-2023\packages\kernel\patches\0225-input-touchscreen-import-Novatek-NVT36xxx-host-download-SPI-driver-for-Lenovo-TB320FC.patch"
s = open(p, encoding="utf-8", newline="").read().replace("\r\n","\n")
a = "+#include <linux/input/touch_common.h>"
b = "+#include <linux/input.h>"
c = "+#include <linux/of_gpio.h>"
d = "+#include <linux/of.h>"
assert s.count(a) == 1 and s.count(c) == 1, (s.count(a), s.count(c))
s = s.replace(a, b).replace(c, d)
open(p, "w", encoding="utf-8", newline="").write(s)
print("fixed 0225:", s.count(b), "input.h lines,", s.count(d), "of.h lines")
