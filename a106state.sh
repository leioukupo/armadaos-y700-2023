#!/system/bin/sh
# lightweight (sysfs only, no i2c) state logger
L=/data/local/tmp/a106s.log
: > $L
i=0
while [ $i -lt 600 ]; do
  i=$((i+1))
  t=$(cut -d. -f1 /proc/uptime)
  p0=$(cat /sys/class/typec/port0/data_role 2>/dev/null)
  p1=$(cat /sys/class/typec/port1/data_role 2>/dev/null)
  xh=$(ls /sys/kernel/debug/usb/xhci 2>/dev/null | tr "\n" ",")
  ids=""
  for d in /sys/bus/usb/devices/*/; do
    v=$(cat $d/idVendor 2>/dev/null)
    r=$(cat $d/idProduct 2>/dev/null)
    s=$(cat $d/speed 2>/dev/null)
    [ -n "$v" ] && ids="$ids $v:$r(${s})"
  done
  echo "T$t p0[$p0] p1[$p1] xhci=$xh usb=$ids" >> $L
  sleep 1
done
