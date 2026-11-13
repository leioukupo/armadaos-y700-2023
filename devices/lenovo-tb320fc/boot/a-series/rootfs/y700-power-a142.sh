#!/bin/sh
# A142: the battery gauge and the USB-C port are owned by the ADSP.  The Android DT has no
# charger node and no fuel gauge, so qcom_battmgr + ucsi_glink over PMIC GLINK are the only
# way to read capacity or negotiate PD.  This tree has no sm8450 battmgr variant, so probe
# falls back to QCOM_BATTMGR_SM8350 and the psy names are qcom-battmgr-bat / -usb / -wls.  The
# PMIC_RTR_ADSP_APPS glink channel is opened by the ADSP itself, so no DT edit is needed.
K=Y700-A142-PWR
LOG=/var/log/y700-power.txt
CONF=/etc/y700-power.conf
KO=/usr/lib/y700
BAT=/sys/class/power_supply/qcom-battmgr-bat
load=on
polls=20
mods="fsa4480 aux-hpd-bridge pmic_glink qcom_battmgr typec_ucsi ucsi_glink pmic_glink_altmode"
upt(){ cut -d . -f 1 /proc/uptime; }
L(){ M="$(upt) $K $*"; echo "$M" >> "$LOG" 2>/dev/null; echo "<5>$M" > /dev/kmsg 2>/dev/null; }
T(){ echo "$K $*" > /dev/tty0 2>/dev/null; }
INSMOD=
for c in /usr/bin/insmod /sbin/insmod /bin/insmod ; do [ -x "$c" ] && { INSMOD=$c; break; }; done
psyn(){ ls /sys/class/power_supply 2>/dev/null | tr "\n" ","; }
tcn(){ ls /sys/class/typec 2>/dev/null | tr "\n" ","; }
g(){ cat "$1" 2>/dev/null; }
psydump(){ R=; for p in /sys/class/power_supply/* ; do [ -d "$p" ] || continue; n=$(basename "$p"); R="$R $n[type=$(g $p/type),stat=$(g $p/status),cap=$(g $p/capacity),volt=$(g $p/voltage_now),cur=$(g $p/current_now),imax=$(g $p/input_current_limit),vmax=$(g $p/voltage_max_limit),tech=$(g $p/technology)]"; done; echo "[$R]"; }
tcdump(){ R=; for c in /sys/class/typec/* ; do [ -d "$c" ] || continue; n=$(basename "$c"); R="$R $n[data=$(g $c/data_role),power=$(g $c/power_role),mode=$(g $c/power_operation_mode),pd=$(g $c/partner/supports_usb_power_delivery)]"; done; echo "[$R]"; }
auxbnd(){ R=; for d in /sys/bus/auxiliary/drivers/* ; do [ -d "$d" ] || continue; R="$R $(basename $d)"; done; echo "[$R]"; }
unk(){ dmesg 2>/dev/null | grep -aiE "unknown symbol|disagrees about version|invalid module|exec format" | tail -n 3 | tr "\n" "|"; }
km(){ dmesg 2>/dev/null | grep -aiE "pmic_glink|battmgr|ucsi|typec|altmode|charger|hpd" | tail -n 12 | tr "\n" "|"; }
[ -f "$CONF" ] && . "$CONF"
L "start ver=$(uname -r) insmod=${INSMOD:-MISSING} psy=[$(psyn)] typec=[$(tcn)] adsp=[$(cat /sys/class/remoteproc/remoteproc*/state 2>/dev/null | tr "\n" ",")]"
if [ "$load" = on ] ; then
	for m in $mods ; do
		if lsmod 2>/dev/null | grep -q "^$m" ; then L "ins $m already-loaded"; continue; fi
		[ -e "$KO/$m.ko" ] || { L "ins $m MISSING-ko"; continue; }
		L "ins $m begin"
		timeout 150 "$INSMOD" "$KO/$m.ko" >> "$LOG" 2>&1; RC=$?
		L "ins $m rc=$RC psy=[$(psyn)] typec=[$(tcn)] unk=[$(unk)]"
	done
	for m in $mods ; do
		lsmod 2>/dev/null | grep -q "^$m" && continue
		[ -e "$KO/$m.ko" ] || continue
		L "ins2 $m begin"
		timeout 150 "$INSMOD" "$KO/$m.ko" >> "$LOG" 2>&1; RC2=$?
		L "ins2 $m rc=$RC2 unk=[$(unk)]"
	done
else
	L "load off"
fi
sleep 3
L "aux drivers=$(auxbnd)"
n=0
while [ $n -lt $polls ] ; do
	n=$((n+1))
	[ -e "$BAT/capacity" ] && { L "battery node n=$n"; break; }
	sleep 1
done
L "psy=$(psydump)"
L "typec=$(tcdump)"
L "state lsmod=[$(lsmod 2>/dev/null | grep -aE "pmic_glink|battmgr|ucsi|fsa4480|hpd" | cut -d " " -f 1 | tr "\n" ",")]"
L "kmsg=[$(km)]"
L "MARK-1 batt-cap=$(g $BAT/capacity) status=$(g $BAT/status) online=$(g /sys/class/power_supply/qcom-battmgr-usb/online) ichg=$(g $BAT/current_now) soh=$(g $BAT/state_of_health)"
L "MARK-2 pd=$(g /sys/class/typec/port0/power_operation_mode)/$(g /sys/class/typec/port1/power_operation_mode) partner-pd=$(g /sys/class/typec/port1/partner/supports_usb_power_delivery) vmax=$(g /sys/class/power_supply/qcom-battmgr-usb/voltage_max) ilim=$(g /sys/class/power_supply/qcom-battmgr-usb/input_current_limit)"
