#!/system/bin/sh
# A106: full state snapshot on STOCK ANDROID (the reference implementation).
mount -t debugfs nodev /sys/kernel/debug 2>/dev/null
echo "uptime=$(cut -d. -f1 /proc/uptime)"
echo "== typec =="
for c in /sys/class/typec/port0 /sys/class/typec/port1; do
  echo "-- $c"
  for f in data_role power_role orientation vbus_source vbus_draw current_max partner; do
    printf "   %s=%s\n" "$f" "$(cat $c/$f 2>/dev/null)"
  done
done
for p in /sys/class/typec/*-partner; do
  echo "-- $p"
  for f in name status partner_shipped_cable vbus_request_mode usb_data_typec; do
    printf "   %s=%s\n" "$f" "$(cat $p/$f 2>/dev/null)"
  done
done
echo "== usb devices =="
for d in /sys/bus/usb/devices/*/; do
  b=$(basename $d)
  sp=$(cat $d/speed 2>/dev/null)
  mfr=$(cat $d/manufacturer 2>/dev/null)
  pr=$(cat $d/product 2>/dev/null)
  vid=$(cat $d/idVendor 2>/dev/null)
  [ -n "$vid" ] && echo "   $b vid=$vid speed=$sp [$mfr / $pr]"
done
echo "== xhci =="
for f in /sys/kernel/debug/usb/xhci/*/ports/port0*/portsc; do
  echo "   $f"
  head -2 $f | tr "\n" " "
  echo
done
echo "== regmaps =="
for a in 5-004f 5-0042 5-0043; do
  f=/sys/kernel/debug/regmap/$a/registers
  if [ -f "$f" ]; then
    printf "   %s:" "$a"
    for r in 04 05 06 08 09 0a 0b 0c 10 11 12 15 16 17 18 1c; do
      v=$(awk -v k="$r:" '$1==k{print $2; exit}' $f)
      printf "%s=%s " "$r" "${v:-NA}"
    done
    echo
  else
    echo "   $a: NO REGMAP"
  fi
done
echo "== gpio =="
grep -E "gpio-?(29|90|91) " /sys/kernel/debug/gpio 2>/dev/null
echo "== dmesg =="
dmesg 2>/dev/null | grep -iE "usb [0-9]-[0-9]|new (high|full|super|wireless) speed|connect|disconnect|eud|repeater|fsa" | tail -10
