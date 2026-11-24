#!/system/bin/sh
# A106: watch Android while the ONLY dwc3 flips from device(port0/PC) to host(port1/G9).
# Run this, then unplug the PC cable; the G9 on the non-charging port should enumerate.
mount -t debugfs nodev /sys/kernel.debug 2>/dev/null
mount -t debugfs nodev /sys/kernel/debug 2>/dev/null
L=/data/local/tmp/a106w.log
: > $L
i=0
while [ $i -lt 100 ]; do
  i=$((i+1))
  t=$(cut -d. -f1 /proc/uptime)
  p0=$(cat /sys/class/typec/port0/data_role 2>/dev/null)
  p1=$(cat /sys/class/typec/port1/data_role 2>/dev/null)
  xh=$(ls /sys/kernel/debug/usb/xhci 2>/dev/null | tr "\n" ",")
  dv=$(ls /sys/bus/usb/devices 2>/dev/null | grep -E "^[0-9]+-[0-9]+" | tr "\n" ",")
  ids=""
  for d in /sys/bus/usb/devices/*/; do
    v=$(cat $d/idVendor 2>/dev/null); r=$(cat $d/idProduct 2>/dev/null); s=$(cat $d/speed 2>/dev/null)
    [ -n "$v" ] && ids="$ids $v:$r(${s})"
  done
  line="T$t p0[$p0] p1[$p1] xhci=$xh dev=$dv usb=$ids"
  for a in 5-004f 5-0042 5-0043; do
    f=/sys/kernel/debug/regmap/$a/registers
    row=""
    for r in 04 05 06 07 08 09 0a 10 11 12 18; do
      v=$(awk -v k="$r:" "\$1==k{print \$2; exit}" $f 2>/dev/null)
      row="$row ${r}=${v:-NA}"
    done
    line="$line | ${a#5-}:$row"
  done
  echo "$line" >> $L
  sleep 1
done
echo "=== dmesg (usb/eud/repeater/role) ===" >> $L
dmesg 2>/dev/null | grep -iE "usb|dwc3|xhci|eud|repeater|fsa|role|typec|ucsi|extcon" | tail -60 >> $L
echo "=== done ===" >> $L
