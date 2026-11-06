#!/bin/sh
# A43 hardware survey, run by the UFS root once per content change.
# Output lands on the card as y700-tasklog.txt.  Read-only: no writes to any
# block device here, the point is to see what the next step can drive.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
echo "===== Y700-A43 survey ====="
echo "up=$(cat /proc/uptime) root=$(awk '$2=="/"{print $1; exit}' /proc/mounts)"
echo "== cmdline =="
cat /proc/cmdline
echo "== net ifaces =="
ls -l /sys/class/net 2>&1
ip -o link 2>&1
echo "== usb/gadget/typec drivers =="
ls /sys/bus/platform/drivers 2>/dev/null | grep -iE 'dwc|usb|qmp|typec|glink|pmic|extcon' | busybox tr '\n' ' '
echo
echo "== usb iomem =="
grep -iE 'dwc|usb|ss-phy|qmp' /proc/iomem 2>/dev/null
echo "== typec / usb_role / power_supply =="
ls -l /sys/class/typec /sys/class/usb_role /sys/class/power_supply 2>&1
for p in /sys/class/power_supply/* ; do
	[ -d "$p" ] || continue
	echo "-- $p type=$(cat $p/type 2>/dev/null) status=$(cat $p/status 2>/dev/null) cap=$(cat $p/capacity 2>/dev/null)"
done
echo "== input devices =="
ls -l /sys/class/input 2>&1
ls -l /dev/input 2>&1
echo "== display =="
ls -l /sys/class/graphics /sys/class/backlight /dev/fb* 2>&1
dmesg | grep -iE 'simple-framebuffer|simplefb|panel|msm_drm|backlight' | tail -n 20
echo "== block =="
ls -l /sys/block 2>&1
cat /proc/partitions
echo "== ufs host =="
ls -l /sys/bus/platform/drivers/ufshcd* 2>&1
echo "== mmc hosts =="
for h in /sys/class/mmc_host/* ; do
	[ -d "$h" ] || continue
	echo "-- $h state=$(cat $h/state 2>/dev/null)"
done
echo "== all platform drivers =="
ls /sys/bus/platform/drivers 2>/dev/null | busybox tr '\n' ' '
echo "== firmware present in this root =="
ls /lib/firmware 2>&1 | busybox tr '\n' ' '
echo "== modules loaded =="
lsmod 2>&1 | busybox tr '\n' ' '
echo "== debugfs y700 =="
ls /sys/kernel/debug 2>/dev/null | busybox tr '\n' ' '
echo "== dmesg errors =="
dmesg | grep -iE 'error|fail|denied|defer' | tail -n 30
echo "===== survey end ====="
