#!/bin/sh
# A133: the machine driver deferred (517) even though the ADSP is up.
# In this tree GPR lives inside apr.c: q6apm/q6prm are aprbus devices created by
# of_register_apr_devices(), and the q6apm probe of_platform_populate()s the
# "dais"/"bedais" children - bedais (qcom,q6apm-lpass-dais) is the cpu component
# the sc8280xp machine needs, so if bedais has no component the card never
# appears.  This round makes that visible and retries the binds from user space,
# because the core stops retrying deferred probes once initcalls are done.
K=Y700-A141-AUD
# A143: the speaker route fix has to be silent - no boot tone, no sweep.
A143_TAG=Y700-A143-SILENT
LOG=/var/log/y700-audio.txt
CONF=/etc/y700-audio.conf
KO=/usr/lib/y700
ADSPFW=/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc
CSFW=/usr/lib/firmware/cirrus
MP=/mnt/acard
echo "<5>A17SELF path=$0 bytes=$(wc -c < "$0") md5=$(md5sum "$0" 2>/dev/null | cut -c1-32) up=$(cut -d . -f 1 /proc/uptime)" > /dev/kmsg 2>/dev/null
mkdir -p /var/lib 2>/dev/null; echo "start up=$(cut -d . -f 1 /proc/uptime) bytes=$(wc -c < "$0")" > /var/lib/y700-audio-run.txt 2>/dev/null
load=on
fwfromcard=on
unmute=on
play=off
retry=on
polls=40
net=on
PINGHOST=10.1.20.28
mods="smp2p qcom_pil_info qcom_glink_smem qcom_common qcom_pd_mapper qcom_q6v5 qcom_q6v5_pas snd-soc-qcom-common snd-q6dsp-common cs_dsp snd-soc-wm-adsp snd-soc-qcom-sdw q6core snd-q6apm q6apm-dai q6apm-lpass-dais q6prm q6prm-clocks snd-soc-cs35l45 snd-soc-cs35l45-i2c snd-soc-sc8280xp"
[ -f "$CONF" ] && . "$CONF"
upt(){ cut -d . -f 1 /proc/uptime; }
L(){ M="$(upt) $K $*"; echo "$M" >> "$LOG" 2>/dev/null; echo "<5>$M" > /dev/kmsg 2>/dev/null; }
C(){ echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
T(){ echo "$K $*" > /dev/tty0 2>/dev/null; }
spkroute(){
	# AudioReach speaker path: PA rails, protection DSP, monitor sources and -
	# this is the part that silently kills output - the two digital PCM volume
	# kcontrols, which come up at 0 (= -102.25 dB).  The "-40dB" text form is
	# rejected by amixer for a mute=1 dBscale control, so only a raw value works.
	nc=$1
	setc(){ amixer -c"$nc" cset "name=$1" "$2" >/dev/null 2>&1 || L "route miss [$1=$2]"; }
	setc "PRIMARY_MI2S_RX Audio Mixer MultiMedia1" 1
	for s in SPK1 SPK2 ; do
		setc "$s AMP Enable Switch" 0
		setc "$s DSP1 Firmware" Protection
		setc "$s Amplifier Mode" SPK
		setc "$s Analog PCM Volume" 0
		setc "$s Digital PCM Volume" 400
		setc "$s DSP_RX1 Source" ASP_RX1
		setc "$s DSP_RX2 Source" ASP_RX2
		setc "$s DSP_RX3 Source" VMON
		setc "$s DSP_RX4 Source" IMON
		setc "$s DSP_RX5 Source" VDD_BATTMON
		setc "$s DSP_RX6 Source" VDD_BSTMON
		setc "$s DSP_RX7 Source" CLASSH_TGT
		setc "$s DSP_RX8 Source" VDD_BATTMON
		setc "$s DACPCM Source" DSP_TX1
		setc "$s DSP1 Preload Switch" 1
		setc "$s AMP Enable Switch" 1
	done
	L "route card$nc applied digvol=400 mixer=MultiMedia1"
}
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
	mountcard || {
		L "push no-card mounts=[$(cut -d " " -f 2 /proc/mounts | tr "\n" ",")]"
		cp -f "$LOG" /var/lib/y700-audio-logcopy.txt 2>/dev/null
		return 1
	}
	tail -n 400 "$LOG" > "$MP/y700-out/y700-audio.tmp" 2>/dev/null && mv -f "$MP/y700-out/y700-audio.tmp" "$MP/y700-out/y700-audio.txt" 2>/dev/null
	L "push wrote=$(wc -c < "$MP/y700-out/y700-audio.txt" 2>/dev/null) card=$AC"
	timeout 30 sync 2>/dev/null
	timeout 30 umount "$MP" 2>/dev/null
}
fw_install(){
	mkdir -p "$ADSPFW" "$CSFW" 2>/dev/null
	have_adsp=0; [ -e "$ADSPFW/adsp.mdt" ] && have_adsp=1
	have_cs=$(ls "$CSFW" 2>/dev/null | wc -l)
	L "fw present adsp=$have_adsp cs=$have_cs"
	if [ "$have_adsp" = 1 ] && [ "$have_cs" -gt 0 ] ; then L "fw both already adsp=$(ls "$ADSPFW" 2>/dev/null | wc -l) cs=$have_cs"; return 0; fi
	mountcard || { L "fw no-card"; return 1; }
	L "fw card adsp=[$(ls "$MP"/y700-fw/adsp 2>/dev/null | tr "\n" ",")] cs=[$(ls "$MP"/y700-fw/cs35l45 2>/dev/null | tr "\n" ",")]"
	n=0
	if [ "$have_adsp" = 0 ] ; then for f in "$MP"/y700-fw/adsp/* ; do cp -f "$f" "$ADSPFW/" 2>/dev/null && n=$((n+1)); done; fi
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
aprdev(){ ls /sys/bus/aprbus/devices 2>/dev/null | tr "\n" ","; }
aprdrv(){ R=; for d in /sys/bus/aprbus/drivers/* ; do [ -d "$d" ] || continue; B=$(ls "$d" 2>/dev/null | grep -v "^module$" | tr "\n" "+"); R="$R $(basename "$d")=[$B]"; done; echo "$R"; }
pldrv(){ R=; for n in q6apm-lpass-dais q6apm-dai q6prm-lpass-clock snd-sc8280xp; do d=/sys/bus/platform/drivers/$n; [ -d "$d" ] || continue; B=$(ls "$d" 2>/dev/null | grep -v "^module$" | tr "\n" "+"); R="$R $n=[$B]"; done; echo "$R"; }
pldev(){ ls /sys/bus/platform/devices 2>/dev/null | grep -aiE "bedais|dais|service|gprsvc|aprsvc|clock-controller|^sound$" | tr "\n" ","; }
dtpd(){ R=; for p in /proc/device-tree/soc/remoteproc*/glink-edge/gpr/service@* ; do [ -d "$p" ] || continue; R="$R $(basename "$p"):pd=$(ls "$p" 2>/dev/null | grep -ac protection-domain)"; done; echo "[svc$R]"; }
aprbnd(){ R=; for d in /sys/bus/aprbus/drivers/* ; do [ -d "$d" ] || continue; B=$(ls "$d" 2>/dev/null | grep -v "^module$" | tr "\n" "+"); R="$R $(basename "$d")=[$B]"; done; echo "[$R]"; }
neta(){ ip -4 -o addr 2>/dev/null | tr "\n" " "; ifconfig -a 2>/dev/null | grep -a "inet " | tr "\n" " "; }
netr(){ ip route 2>/dev/null | tr "\n" " "; }
wifist(){ nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr "\n" "|"; nmcli -t -f NAME connection show --active 2>/dev/null | tr "\n" "|"; }
cards(){ sed -n "2,10p" /proc/asound/cards 2>/dev/null | tr -s "\n\t" " "; }
km(){ dmesg 2>/dev/null | grep -aiE "gpr|apr|apm|prm|q6|pdr|protection|defer|remoteproc|adsp|asoc|sound|cs35|component" | tail -n 14 | tr "\n" "|"; }
unk(){ dmesg 2>/dev/null | grep -aiE "unknown symbol|disagrees about version|invalid module|exec format" | tail -n 3 | tr "\n" "|"; }
asoc(){ dmesg 2>/dev/null | grep -aiE "q6apm|q6prm|lpass|sc8280|cs35l45|ASoC|soc-core|soc-pcm|error getting" | tail -n 16 | tr "\n" "|"; }
pdrvall(){ ls /sys/bus/platform/drivers 2>/dev/null | grep -aiE "q6|lpass|sc8280|apm|prm|snd" | tr "\n" ","; }
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
L "dtb $(dtpd) aprdev=[$(aprdev)]"
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
		[ "$RC" = 0 ] || L "ins $m unk=[$(unk)]"
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
		case "$m" in q6prm-clocks|q6prm|snd-q6apm|q6apm-lpass-dais|q6apm-dai|snd-soc-sc8280xp) sleep 2; L "settle $m apr=[$(aprdrv)] pdrv=[$(pldrv)] deferred=[$(dfr)]"; push ;; esac
	done
	for m in $mods ; do
		lsmod 2>/dev/null | grep -q "^$m" && continue
		[ -e "$KO/$m.ko" ] || continue
		L "ins2 $m begin"
		timeout 150 "$INSMOD" "$KO/$m.ko" >> "$LOG" 2>&1; RC2=$?
		L "ins2 $m rc=$RC2 unk=[$(unk)]"
	done
	sleep 2
else
	L "load off"
fi
	L "pdm ko=$(lsmod 2>/dev/null | grep -ac qcom_pd_mapper) dtb=$(dtpd) pdr=[$(dmesg 2>/dev/null | grep -aiE \"PDR:|PDM:|no support for the platform\" | tail -n 5 | tr \"\\n\" \"|\")]"
L "survey apr=[$(aprdev)] aprdrv=[$(aprdrv)] pdev=[$(pldev)] pdrv=[$(pldrv)]"
L "survey deferred=[$(dfr)] cards=[$(cards)]"
L "survey kmsg=[$(km)]"
L "survey pdrv-all=[$(pdrvall)]"
L "survey aprdev=[$(aprdev)] aprdrv-names=[$(ls /sys/bus/aprbus/drivers 2>/dev/null | tr "\n" ",")]"
L "survey deferred-full=[$(dfr)]"
L "survey asoc=[$(asoc)]"
push
if [ "$retry" = on ] ; then
	n=0
	while [ $n -lt "$polls" ] ; do
		n=$((n+1))
		if [ -e /proc/asound/card0 ] ; then L "card n=$n"; break; fi
		for d in /sys/bus/aprbus/drivers/* ; do
			[ -d "$d" ] || continue
			for dv in $(ls /sys/bus/aprbus/devices 2>/dev/null) ; do
				[ -e "$d/$dv" ] && continue
				echo "$dv" > "$d/bind" 2>/dev/null && L "aprbind $(basename "$d") $dv ok"
			done
		done
		for drv in q6prm-lpass-clock q6apm-lpass-dais q6apm-dai snd-sc8280xp; do
			dd=/sys/bus/platform/drivers/$drv
			[ -d "$dd" ] || continue
			for dv in $(ls /sys/bus/platform/devices 2>/dev/null | grep -aiE "bedais|dais|clock-controller") ; do
				[ -e "$dd/$dv" ] && continue
				echo "$dv" > "$dd/bind" 2>/dev/null && L "bind $drv $dv ok"
			done
		done
		if [ -d /sys/bus/platform/drivers/snd-sc8280xp ] && [ ! -e /sys/bus/platform/drivers/snd-sc8280xp/sound ] ; then
			echo sound > /sys/bus/platform/drivers/snd-sc8280xp/bind 2>/dev/null
			L "bindn sound rc=$? deferred=[$(dfr)]"
		fi
		if [ $((n % 5)) = 0 ] ; then
			L "poll n=$n cards=[$(cards)] apr=[$(aprdev)] aprdrv=[$(aprbnd)] pdrv=[$(pldrv)] deferred=[$(dfr)]"
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
		if amixer -c"$c" controls 2>/dev/null | grep -aq "PRIMARY_MI2S_RX Audio Mixer" ; then
			spkroute "$c"
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
if [ "$net" = on ] ; then
	L "net dev=[$(ls /sys/class/net 2>/dev/null | tr "\n" ",")] addr=[$(neta)]"
	L "net route=[$(netr)] wifi=[$(wifist)]"
	L "net ping=$PINGHOST ok=$(ping -c 1 -W 3 "$PINGHOST" 2>/dev/null | grep -ac bytes=)"
	push
fi
L "end state=[$(rpstate)] cards=[$(cards)] deferred=[$(dfr)]"
push
exit 0
