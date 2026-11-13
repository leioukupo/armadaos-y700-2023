#!/bin/sh
# A133: the machine driver deferred (517) even though the ADSP is up.
# In this tree GPR lives inside apr.c: q6apm/q6prm are aprbus devices created by
# of_register_apr_devices(), and the q6apm probe of_platform_populate()s the
# "dais"/"bedais" children - bedais (qcom,q6apm-lpass-dais) is the cpu component
# the sc8280xp machine needs, so if bedais has no component the card never
# appears.  This round makes that visible and retries the binds from user space,
# because the core stops retrying deferred probes once initcalls are done.
K=Y700-A136-AUD
LOG=/var/log/y700-audio.txt
CONF=/etc/y700-audio.conf
KO=/usr/lib/y700
ADSPFW=/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc
CSFW=/usr/lib/firmware/cirrus
MP=/mnt/acard
load=on
fwfromcard=on
unmute=on
play=on
retry=on
polls=40
mods="qcom_pil_info smp2p qcom_glink_smem qcom_common qcom_q6v5 qcom_q6v5_pas snd-soc-qcom-common snd-q6dsp-common cs_dsp snd-soc-wm-adsp snd-soc-qcom-sdw q6core q6prm q6prm-clocks snd-q6apm q6apm-lpass-dais q6apm-dai snd-soc-cs35l45 snd-soc-cs35l45-i2c snd-soc-sc8280xp"
[ -f "$CONF" ] && . "$CONF"
upt(){ cut -d . -f 1 /proc/uptime; }
L(){ M="$(upt) $K $*"; echo "$M" >> "$LOG" 2>/dev/null; echo "<5>$M" > /dev/kmsg 2>/dev/null; }
C(){ echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
T(){ echo "$K $*" > /dev/tty0 2>/dev/null; }
mountcard(){
	mkdir -p "$MP" 2>/dev/null
	for d in /dev/mmcblk*p[0-9] ; do
		timeout 20 mount -t vfat -o rw,sync "$d" "$MP" 2>/dev/null || continue
		if [ -d "$MP/y700-out" ] ; then AC=$d; return 0; fi
		timeout 20 umount "$MP" 2>/dev/null
	done
	AC=""
	return 1
}
pushed_to(){ R=; while read -r dv mp rest ; do [ -n "$mp" ] || continue; [ -d "$mp/y700-out" ] && { R=$mp; break; }; done < /proc/mounts; echo "$R"; }
push(){
	DST=$(pushed_to)
	if [ -n "$DST" ] ; then
		tail -n 400 "$LOG" > "$DST/y700-out/y700-audio.tmp" 2>/dev/null && mv -f "$DST/y700-out/y700-audio.tmp" "$DST/y700-out/y700-audio.txt" 2>/dev/null
		L "push shared-mount dst=$DST bytes=$(wc -c < "$DST/y700-out/y700-audio.txt" 2>/dev/null)"
		timeout 30 sync 2>/dev/null
		return 0
	fi
	mountcard || { L "push no-card mounts=[$(cut -d " " -f 2 /proc/mounts | tr "\n" ",")]"; return 1; }
	tail -n 400 "$LOG" > "$MP/y700-out/y700-audio.tmp" 2>/dev/null && mv -f "$MP/y700-out/y700-audio.tmp" "$MP/y700-out/y700-audio.txt" 2>/dev/null
	L "push wrote=$(wc -c < "$MP/y700-out/y700-audio.txt" 2>/dev/null) card=$AC"
	timeout 30 sync 2>/dev/null
	timeout 30 umount "$MP" 2>/dev/null
}
fw_install(){
	mkdir -p "$ADSPFW" "$CSFW" 2>/dev/null
	if [ -e "$ADSPFW/adsp.mdt" ] ; then L "fw adsp already files=$(ls "$ADSPFW" 2>/dev/null | wc -l)"; return 0; fi
	mountcard || { L "fw no-card"; return 1; }
	n=0
	for f in "$MP"/y700-fw/adsp/* ; do cp -f "$f" "$ADSPFW/" 2>/dev/null && n=$((n+1)); done
	m=0
	for f in "$MP"/y700-fw/cs35l45/* ; do cp -f "$f" "$CSFW/" 2>/dev/null && cp -f "$f" /usr/lib/firmware/ 2>/dev/null && m=$((m+1)); done
	timeout 30 sync 2>/dev/null
	timeout 30 umount "$MP" 2>/dev/null
	L "fw from-card adsp=$n cs35=$m"
}
INSMOD=
for c in /usr/bin/insmod /sbin/insmod /bin/insmod ; do [ -x "$c" ] && { INSMOD=$c; break; }; done
rpstate(){ cat /sys/class/remoteproc/remoteproc*/state 2>/dev/null | tr "\n" "," ; }
dbgs(){ grep -q " /sys/kernel/debug debugfs" /proc/mounts || mount -t debugfs none /sys/kernel/debug 2>/dev/null; }
dfr(){ dbgs; cat /sys/kernel/debug/devices_deferred 2>/dev/null | tr "\n" ","; }
aprdev(){ ls /sys/bus/apr/devices 2>/dev/null | tr "\n" ","; }
aprdrv(){ R=; for d in /sys/bus/apr/drivers/* ; do [ -d "$d" ] || continue; B=$(ls "$d" 2>/dev/null | grep -v "^module$" | tr "\n" "+"); R="$R $(basename "$d")=[$B]"; done; echo "$R"; }
pldrv(){ R=; for n in q6apm-lpass-dais q6apm-dai q6prm-clocks snd-sc8280xp qcom,smp2p; do d=/sys/bus/platform/drivers/$n; [ -d "$d" ] || continue; B=$(ls "$d" 2>/dev/null | grep -v "^module$" | tr "\n" "+"); R="$R $n=[$B]"; done; echo "$R"; }
pldev(){ ls /sys/bus/platform/devices 2>/dev/null | grep -aiE "bedais|dais|service|gprsvc|aprsvc|clock-controller|^sound$" | tr "\n" ","; }
cards(){ sed -n "2,10p" /proc/asound/cards 2>/dev/null | tr -s "\n\t" " "; }
km(){ dmesg 2>/dev/null | grep -aiE "gpr|apr|apm|prm|q6|pdr|protection|defer|remoteproc|adsp|asoc|sound|cs35|component" | tail -n 14 | tr "\n" "|"; }
L "self path=$0 bytes=$(wc -c < "$0") md5=$(md5sum "$0" 2>/dev/null | cut -c1-32)"
L "conf load=$load fwfromcard=$fwfromcard unmute=$unmute play=$play retry=$retry polls=$polls"
L "start ver=$(uname -r) insmod=${INSMOD:-MISSING} adspfw=$(ls "$ADSPFW" 2>/dev/null | wc -l) csfw=$(ls "$CSFW" 2>/dev/null | wc -l) rp=[$(ls /sys/class/remoteproc 2>/dev/null | tr "\n" ",")] retry=$retry polls=$polls"
bootsha(){ p="$1"; [ -b "$p" ] || { echo "-"; return; }; timeout 240 sha256sum "$p" 2>/dev/null | cut -c1-64; }
L "self path=$0 bytes=$(wc -c < "$0") mtime=$(date -r "$0" -Iseconds 2>/dev/null) enabled=[$(systemctl is-enabled y700-audio.service 2>/dev/null)]"
L "cmdline=[$(cat /proc/cmdline 2>/dev/null)]"
L "bootparts=[$(ls /dev/disk/by-name /dev/block/by-name 2>/dev/null | grep -aiE "^boot" | tr "\n" ",")]"
for bp in /dev/disk/by-name/boot_a /dev/disk/by-name/boot_b ; do
	[ -b "$bp" ] || continue
	SHA=$(bootsha "$bp")
	[ "$SHA" = "-" ] || L "bootsha $bp size=$(blockdev --getsize64 "$bp" 2>/dev/null) sha=$SHA"
done
L "pre apr=[$(aprdev)] aprdrv=[$(aprdrv)] pdev=[$(pldev)] deferred=[$(dfr)]"
push
if [ "$fwfromcard" = on ] ; then fw_install; push; fi
if [ "$load" = on ] ; then
	for m in $mods ; do
		if lsmod 2>/dev/null | grep -q "^$m" ; then L "ins $m already-loaded"; continue; fi
		if [ ! -e "$KO/$m.ko" ] ; then L "ins $m MISSING-ko"; continue; fi
		L "ins $m begin"
		T "ins $m"
		timeout 150 "$INSMOD" "$KO/$m.ko" >> "$LOG" 2>&1; RC=$?
		L "ins $m rc=$RC apr=[$(aprdrv)] pdrv=[$(pldrv)] deferred=[$(dfr)]"
		push
		if [ "$m" = qcom_q6v5_pas ] ; then
			n=0
			while [ $n -lt 25 ] ; do
				n=$((n+1))
				case "$(rpstate)" in *running*) break ;; esac
				sleep 1
			done
			L "adsp wait=$n state=[$(rpstate)]"
			L "adsp kmsg=[$(km)]"
			push
		fi
		case "$m" in q6prm-clocks|snd-q6apm|q6apm-lpass-dais) sleep 2; L "settle $m apr=[$(aprdrv)] pdrv=[$(pldrv)] deferred=[$(dfr)]"; push ;; esac
	done
else
	L "load off"
fi
L "survey apr=[$(aprdev)] aprdrv=[$(aprdrv)] pdev=[$(pldev)] pdrv=[$(pldrv)]"
L "survey deferred=[$(dfr)] cards=[$(cards)]"
L "survey kmsg=[$(km)]"
push
if [ "$retry" = on ] ; then
	n=0
	while [ $n -lt "$polls" ] ; do
		n=$((n+1))
		if [ -e /proc/asound/card0 ] ; then L "card n=$n"; break; fi
		for drv in q6apm-lpass-dais q6apm-dai q6prm-clocks snd-sc8280xp; do
			dd=/sys/bus/platform/drivers/$drv
			[ -d "$dd" ] || continue
			for dv in $(ls /sys/bus/platform/devices 2>/dev/null | grep -aiE "bedais|clock-controller") ; do
				[ -e "$dd/$dv" ] && continue
				echo "$dv" > "$dd/bind" 2>/dev/null && L "bind $drv $dv ok"
			done
		done
		if [ -d /sys/bus/platform/drivers/snd-sc8280xp ] && [ ! -e /sys/bus/platform/drivers/snd-sc8280xp/sound ] ; then
			echo sound > /sys/bus/platform/drivers/snd-sc8280xp/bind 2>/dev/null
			L "bindn sound rc=$? deferred=[$(dfr)]"
		fi
		if [ $((n % 5)) = 0 ] ; then
			L "poll n=$n cards=[$(cards)] pdrv=[$(pldrv)] deferred=[$(dfr)]"
			push
		fi
		sleep 2
	done
	L "retry done n=$n cards=[$(cards)]"
	push
fi
if [ "$unmute" = on ] ; then
	c=0
	while [ $c -lt 4 ] ; do
		names=$(amixer -c"$c" controls 2>/dev/null | sed -n "s/.*name=//p" | tr -d "\047")
		if [ -n "$names" ] ; then
			L "mixer card$c lines=$(echo "$names" | wc -l)"
			echo "$names" | while read nm ; do
				amixer -c"$c" sset "$nm" 100% unmute >> "$LOG" 2>&1 && L "mixer card$c up [$nm]"
			done
		fi
		c=$((c+1))
	done
fi
if [ "$play" = on ] ; then
	if command -v speaker-test >/dev/null 2>&1 ; then
		timeout 12 speaker-test -D "plughw:0,0" -c 2 -t sine -f 440 -l 1 >> "$LOG" 2>&1; L "play speaker-test rc=$?"
	elif [ -x /usr/bin/pw-play ] ; then
		timeout 12 pw-play /usr/share/sounds/freedesktop/stereo/bell.oga >> "$LOG" 2>&1; L "play pw-play rc=$?"
	else
		L "play no-tool"
	fi
	T "audio survey done"
	push
fi
L "end state=[$(rpstate)] cards=[$(cards)] deferred=[$(dfr)]"
push
exit 0
