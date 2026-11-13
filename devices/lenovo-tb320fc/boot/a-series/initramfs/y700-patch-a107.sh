#!/bin/sh
# A107: rootfs patch that runs from inside the kernel initramfs.
#
#   $1 = the block device of the root we are about to enter
#   $2 = where that root is mounted rw (/mnt/root)
#
# Why here and not on the card: the SD card has started throwing read errors
# (FAT "bread failed" on the reader), and everything about the installed system
# is already independent of it.  Shipping the patch inside the boot image makes
# a rootfs change a single "fastboot flash boot_b".
#
# What it does: hands the panel from our debug weston session over to the
# distro's own desktop - SDDM autologin as the "armada" user into
# armada-plasma-mobile.desktop - and arms a one-shot unit that grows the Linux
# root filesystem into the rest of its partition.  Nothing outside the Linux
# partition is touched: no partition table, no boot_a, no userdata.
DEV=$1
R=$2
K="Y700-A107"
P() { echo "<3>$K $*"; }
LOG="$R/var/log/y700-a107.txt"
DONE="$R/var/lib/y700/a107.done"
U() { echo "$*" >> "$LOG" 2>/dev/null; }

[ -n "$R" ] || { P "REFUSE no root mountpoint"; exit 1; }
[ -d "$R/usr/lib/systemd/system" ] || { P "REFUSE $R is not the Armada root"; exit 1; }
if [ -e "$DONE" ]; then
	P "already applied ($(cat "$DONE" 2>/dev/null)), nothing to do"
	exit 0
fi
mkdir -p "$R/var/log" "$R/var/lib/y700" "$R/etc/systemd/system" 2>/dev/null
echo "=== $K patch up=$(cut -d . -f 1 /proc/uptime) dev=$DEV root=$R ===" > "$LOG" 2>/dev/null
P "patch start dev=$DEV"

# ---- 1. what the distro actually ships for the graphical session ----
{
	echo "--- sddm ---"
	ls -l "$R/usr/bin/sddm" "$R/usr/lib/systemd/system/sddm.service" 2>&1
	echo "--- sddm.conf + conf.d ---"
	ls -l "$R/etc/sddm.conf" "$R/etc/sddm.conf.d" 2>&1
	for f in "$R"/etc/sddm.conf.d/*.conf; do
		[ -f "$f" ] || continue
		echo "== $f"; cat "$f" 2>&1
	done
	echo "--- wayland sessions ---"
	ls -l "$R/usr/share/wayland-sessions" 2>&1
	echo "--- plasma binaries ---"
	ls -l "$R/usr/bin/kwin_wayland" "$R/usr/bin/startplasma-wayland" "$R/usr/bin/plasma-mobile-session" "$R/usr/libexec/armada/armada-plasma-session" 2>&1
	echo "--- masked units ---"
	for f in "$R"/etc/systemd/system/*; do
		[ -L "$f" ] || continue
		[ "$(readlink "$f")" = "/dev/null" ] && echo "MASKED ${f##*/}"
	done
	echo "--- wants ---"
	for d in graphical multi-user; do
		echo "[$d.target.wants]"; ls -l "$R/etc/systemd/system/$d.target.wants" 2>&1
	done
	echo "--- user + e2fsprogs ---"
	grep -a '^armada:' "$R/etc/passwd" 2>&1
	ls -l "$R/usr/sbin/resize2fs" 2>&1
} >> "$LOG" 2>&1
P "survey lines=$(wc -l < "$LOG" 2>/dev/null)"

# ---- 2. arm SDDM autologin into Plasma Mobile ----
if [ ! -f "$R/usr/lib/systemd/system/sddm.service" ]; then
	P "NO sddm.service in the root - weston session stays as it is"
	U "ABORT no sddm.service"
	exit 1
fi
mkdir -p "$R/etc/sddm.conf.d" "$R/etc/systemd/system/graphical.target.wants" 2>/dev/null
# zz- sorts last, so this Session= wins over the distro's own armada.conf.
printf "[Autologin]\nUser=armada\nSession=armada-plasma-mobile.desktop\nRelogin=true\n" > "$R/etc/sddm.conf.d/zz-y700-autologin.conf"
U "autologin=$(tr "\n" ";" < "$R/etc/sddm.conf.d/zz-y700-autologin.conf")"
# armada-session-default rewrites the autologin session to game mode each boot;
# A87 already masked it, mask it again in case a later round unmasked it.
ln -sf /dev/null "$R/etc/systemd/system/armada-session-default.service"
U "armada-session-default masked (autologin stays ours)"
# an unclean earlier round could have masked sddm itself.
if [ -L "$R/etc/systemd/system/sddm.service" ] && [ "$(readlink "$R/etc/systemd/system/sddm.service")" = "/dev/null" ]; then
	rm -f "$R/etc/systemd/system/sddm.service"
	U "unmasked sddm.service"
fi
ln -sf ../sddm.service "$R/etc/systemd/system/graphical.target.wants/sddm.service"
U "sddm wanted by graphical.target"

# ---- 3. our debug weston session must not fight it for the DRM master ----
rm -f "$R/etc/systemd/system/multi-user.target.wants/y700-desktop.service"
U "y700-desktop.service removed from multi-user.target.wants (unit file kept as a fallback)"

# ---- 4. grow the Linux root into the rest of p16, once, from systemd ----
# Not done here: the initramfs has no resize2fs.  The unit runs it online
# against / (p16 is 675529368 sectors, the ext4 inside it only 15 GiB).  A
# resize2fs grow appends block groups - it moves no data and rewrites no
# partition table - and the path condition makes it a no-op after the first run.
cat > "$R/etc/systemd/system/y700-resize.service" <<'RU'
[Unit]
Description=Y700 A107 grow the Linux root filesystem into its own UFS partition
ConditionPathExists=!/var/lib/y700/resize.done
ConditionPathIsReadWrite=/
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/resize2fs /dev/sda16
ExecStartPost=/usr/bin/touch /var/lib/y700/resize.done
StandardOutput=journal
StandardError=journal
RU
ln -sf ../y700-resize.service "$R/etc/systemd/system/multi-user.target.wants/y700-resize.service"
U "y700-resize.service armed"

# ---- 5. leave a readable trace on the panel console ----
P "plasma-mobile armed: session=$(sed -n 's/^Session=//p' "$R/etc/sddm.conf.d/zz-y700-autologin.conf" 2>/dev/null)"
P "resize armed: p16 sectors=$(cat /sys/block/sda/sda16/size 2>/dev/null) sda=$(cat /sys/block/sda/size 2>/dev/null)"
echo "$K applied up=$(cut -d . -f 1 /proc/uptime)" > "$DONE" 2>/dev/null
P "A107 APPLIED"
exit 0
