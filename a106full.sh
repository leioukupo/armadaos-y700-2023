#!/system/bin/sh
# full 0x00-0x1f snapshot of the three analog switches, with attach context
for a in 5-004f 5-0042 5-0043; do
  f=/sys/kernel/debug/regmap/$a/registers
  printf "== %s ==\n" "$a"
  awk '{printf "%s%s", $1, ($2==""?"":"="$2)}' $f | sed 's/  */ /g'
  echo
done
echo "gpio: $(grep -E "gpio-?(90|91) " /sys/kernel/debug/gpio | tr -d "\n")"
echo "xhci: $(for f in /sys/kernel/debug/usb/xhci/*/ports/port0*/portsc; do printf "%s=%s " "$(basename $(dirname $f))" "$(head -1 $f | tr -d "\n")"; done)"
echo "dev: $(for d in /sys/bus/usb/devices/*/; do v=$(cat $d/idVendor 2>/dev/null); r=$(cat $d/idProduct 2>/dev/null); s=$(cat $d/speed 2>/dev/null); [ -n "$v" ] && printf "%s:%s(%s) " $v $r $s; done)"
