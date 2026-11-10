#!/bin/sh
# A87: patch the installed UFS root (/dev/sda16) so an ArmadaOS boot can be seen
# and diagnosed - no reflash, no re-install, only files under /etc.
#
# What this round answers:
#  * the panel is frozen on the "Preparing Armada" PICTURE: armada-splash-early
#    paints a PNG over fb0 and blanks console text, so nothing systemd says ever
#    reaches the glass. It has a supported off switch (/etc/armada/splash-disabled),
#    and the splash/hotkey units also get masked -> fbcon text on the panel again.
#  * no health report ever appeared on the card: y700-health.service is wanted by
#    multi-user.target and emergency.target, so neither was reached - the boot is
#    parked in a job with no timeout. y700-diag.service hangs off sysinit.target,
#    which is demonstrably reached, so it always reports.
#  * a pile of Legion/Steam-Deck units (tb323fu EC, rgb, decky, steam, lvm, md,
#    guestos erofs loop mount) are wanted by this root and cannot work here.
# Everything masked is a weak (Wants=) dependency, so masking cannot break a target.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
K="Y700-A87-PATCH"
CARD=/mnt/card
OUT=$CARD/y700-a87-patch.txt
WANT_SZS=675529368
m() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
UP() { cut -d. -f1 /proc/uptime; }
U() { echo "$*" >> "$OUT" 2>/dev/null; sync; }

RD=$(awk '$2=="/"{print $1; exit}' /proc/mounts)
case "$RD" in
	*mmcblk*) : ;;
	*) m "REFUSE root is $RD, not the card"; exit 1 ;;
esac
echo "=== Y700-A87 ufs-root patch up=$(UP) ===" > "$OUT" 2>/dev/null
U "rootdev=$RD"
m "START up=$(UP)"

[ -b /dev/sda16 ] || mknod /dev/sda16 b 8 16 2>/dev/null
SZS=$(cat /sys/block/sda/sda16/size 2>/dev/null)
U "sda16 sectors=$SZS want=$WANT_SZS"
[ "$SZS" = "$WANT_SZS" ] || { m "REFUSE sda16 size $SZS"; exit 1; }

mkdir -p /mnt/ufs 2>/dev/null
MSG=$(mount -t ext4 -o rw /dev/sda16 /mnt/ufs 2>&1)
MR=$?
U "mount rc=$MR msg=$MSG"
[ "$MR" = "0" ] || { m "REFUSE cannot mount sda16 rw"; exit 1; }
R=/mnt/ufs
[ -x "$R/usr/lib/systemd/systemd" ] || { m "REFUSE no systemd in root"; umount /mnt/ufs; exit 1; }
[ -d "$R/etc/systemd/system" ] || { m "REFUSE no etc/systemd/system"; umount /mnt/ufs; exit 1; }
U "init=$(ls -l $R/sbin/init 2>/dev/null)"

# 1. panel back to the console - the splash units are the only thing drawing on it.
mkdir -p "$R/etc/armada"
: > "$R/etc/armada/splash-disabled"
U "splash-disabled=$(ls -l $R/etc/armada/splash-disabled 2>/dev/null)"
MASK="armada-splash-early.service armada-splash-stall.service
armada-splash-poweroff-screen.service armada-splash-reboot-screen.service
armada-boot-hotkeys.service
armada-als-bridge.service armada-controller-type.service armada-decky-sync.service
armada-g9-double-home.service armada-input-calibration.service armada-rgb.service
armada-rgb-brightness-watch.path armada-rgb-brightness-watch.service
armada-waydroid-input.service armada-guestos.service usr-share-guestos-android.mount
armada-steam-oobe.path armada-steam-oobe.service armada-steamapps.service
armada-flatpak-setup.service flatpak-add-fedora-repos.service plugin_loader.service
inputplumber.service steamos-manager.service armada-mtp.service armada-powerd.service
armada-update-reserve.service armada-installer-visibility.service
armada-session-default.service armada-device-quirks.service armada-fixups.service
armada-control.service lvm2-monitor.service lvm2-lvmpolld.socket
lvm-devices-import.path lvm-devices-import.service mdmonitor.service sssd.service
bootloader-update.service armada-bootimg-sync.service"
N=0
for u in $MASK; do
	ln -sf /dev/null "$R/etc/systemd/system/$u" && N=$((N + 1))
done
U "masked=$N"
m "MASKED $N"

# 2. a report even when multi-user is never reached (quoted heredoc: written as-is).
mkdir -p "$R/usr/local/sbin"
cat > "$R/usr/local/sbin/y700-diag.sh" <<'DIAG'
#!/bin/sh
# A87: systemd is parked somewhere before multi-user.target. Put the pending jobs,
# the running/waiting units and the journal on the SD card, and say so on the panel.
# Every query is wrapped in timeout so one hung unit cannot eat the report.
CARD=""
for d in /dev/disk/by-label/ARMADA /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/mmcblk2p1; do
	[ -b "$d" ] || continue
	mount -o rw "$d" /mnt/card 2>/dev/null && { CARD="$d"; break; }
done
[ -n "$CARD" ] || echo "no card at up=$(cut -d. -f1 /proc/uptime)" > /tmp/y700-a87-nocard.txt
T() { timeout 25 "$@" 2>&1; }
S() {
	U=/mnt/card/y700-a87-sys.txt
	{
		echo "===== Y700-A87-DIAG up=$(cut -d. -f1 /proc/uptime) $(date -u) ====="
		echo "-- cmdline --"; cat /proc/cmdline
		echo "-- os-release --"; head -3 /usr/lib/os-release
		echo "-- is-system-running --"; T systemctl is-system-running
		echo "-- list-jobs --"; T systemctl list-jobs
		echo "-- deps of pending jobs --"
		for j in $(T systemctl list-jobs --no-pager --no-legend | awk '{print $2}'); do
			echo "  == $j"; T systemctl list-dependencies "$j"
		done
		echo "-- state=running --"; T systemctl list-units --all --state=running --no-pager --no-legend
		echo "-- state=waiting --"; T systemctl list-units --all --state=waiting --no-pager --no-legend | head -40
		echo "-- failed --"; T systemctl list-units --failed --no-pager --no-legend
		echo "-- critical-chain --"; T systemd-analyze critical-chain multi-user.target
		echo "-- graphics --"; ls -l /dev/dri /sys/class/graphics 2>&1
		echo "-- backlight --"; ls -l /sys/class/backlight 2>&1
		echo "-- input --"; ls /sys/class/input 2>&1
		echo "-- net --"; T ip -o addr; ls /sys/class/net 2>&1
		echo "-- storage --"; T df -h /
		echo "-- journal warning --"; T journalctl -b --no-pager -p warning | tail -70
		echo "-- journal err --"; T journalctl -b --no-pager -p err | head -50
	} > "$U" 2>&1
	sync
	echo "Y700-A87-DIAG-WRITTEN up=$(cut -d. -f1 /proc/uptime)" >> /mnt/card/y700-a87-marker.txt
	sync
}
echo 8 4 1 7 > /proc/sys/kernel/printk
printf '\nY700-A87-DIAG in 30s - keep the card in the tablet\n' > /dev/console
sleep 30
S
printf 'Y700-A87-DIAG-DONE the card now holds y700-a87-sys.txt\n' > /dev/console
exit 0
DIAG
chmod 0755 "$R/usr/local/sbin/y700-diag.sh"
cat > "$R/etc/systemd/system/y700-diag.service" <<'UNIT'
[Unit]
Description=Y700 A87 systemd state report onto the SD card
DefaultDependencies=no
After=sysinit.target
Before=shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=900
StandardOutput=tty
StandardError=tty
TTYPath=/dev/console
TTYReset=yes
ExecStart=/usr/local/sbin/y700-diag.sh

[Install]
WantedBy=sysinit.target
UNIT
mkdir -p "$R/etc/systemd/system/sysinit.target.wants"
ln -sf ../y700-diag.service "$R/etc/systemd/system/sysinit.target.wants/y700-diag.service"
ln -sf ../y700-diag.service "$R/etc/systemd/system/emergency.target.wants/y700-diag.service"
U "diag script+unit installed"

# 3. make the default target match the forced cmdline instead of graphical.target.
ln -sf /usr/lib/systemd/system/multi-user.target "$R/etc/systemd/system/default.target"
U "default.target=$(readlink $R/etc/systemd/system/default.target)"
U "multi-user-wants: $(ls $R/etc/systemd/system/multi-user.target.wants 2>/dev/null | busybox tr '\n' ' ')"
U "sysinit-wants: $(ls $R/etc/systemd/system/sysinit.target.wants 2>/dev/null | busybox tr '\n' ' ')"

sync; sync
umount /mnt/ufs 2>/dev/null || m "umount busy"
echo "UFS_ARMADA_DONE" > "$CARD/y700-ufs.txt"
sync
U "marker y700-ufs.txt=$(cat $CARD/y700-ufs.txt)"
m "PATCHED masked=$N rebooting in 6s"
sleep 6
busybox reboot -f
m "reboot -f did not happen"
sleep 300
exit 0