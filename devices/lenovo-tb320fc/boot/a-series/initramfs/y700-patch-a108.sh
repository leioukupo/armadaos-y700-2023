#!/bin/sh
# A108: take the evidence out of the installed root, then arm Plasma Mobile.
#
#   $1 = block device of the root we are about to enter
#   $2 = where that root is mounted rw (/mnt/root)
#   $3 = the SD card device /init already recognised (empty when there is none)
#
# Two jobs, in this order:
#
# 1) Retrieve.  The UFS root keeps /var/log from the previous boot (the A107
#    survey, and from now on y700-diag.txt) and nothing outside the initramfs
#    can read that partition, so this is the only way to find out what systemd
#    actually did.  Everything found is copied to <card>/y700-out/ before this
#    round writes anything new, so a round can always read the last one.
#
# 2) Arm.  The A107 handover, plus what A107 could not verify: sddm ships
#    Restart=always with StartLimitIntervalSec=30/StartLimitBurst=2, so three
#    crashes inside half a minute park the display manager for good and the
#    panel falls back to the fbcon console - which is exactly the endless
#    "Y700-HB" log scroll that was reported.  A108 removes that start limit,
#    installs a diagnostic unit that journals the session state (to the card as
#    well), keeps a weston fallback so the panel is never dead, and masks the
#    two distro units that write to the EFI System Partition - on this board the
#    ESP is an Android partition, and /KERNEL on it is what ABL loads.
DEV=$1
R=$2
CARD=$3
K="Y700-A108"
P() { echo "<3>$K $*"; }
LOG="$R/var/log/y700-a108.txt"
DONE="$R/var/lib/y700/a108.done"
U() { echo "$*" >> "$LOG" 2>/dev/null; }

[ -n "$R" ] || { P "REFUSE no root mountpoint"; exit 1; }
[ -d "$R/usr/lib/systemd/system" ] || { P "REFUSE $R is not the Armada root"; exit 1; }
mkdir -p "$R/var/log" "$R/var/lib/y700" "$R/etc/systemd/system" 2>/dev/null
P "patch start dev=$DEV card=[$CARD] up=$(cut -d . -f 1 /proc/uptime)"

# ---- 1. evidence: root -> SD card, before anything new is written ----
case "$CARD" in
    /dev/mmcblk*) ;;
    *) CARD="" ;;
esac
if [ -z "$CARD" ] ; then
    P "RETRIEVE skipped: no mmc card in this boot"
else
    mkdir -p /mnt/card 2>/dev/null
    COK=""
    for f in vfat ext4 ext2 ; do
        if mount -t $f -o rw "$CARD" /mnt/card 2>/dev/null ; then COK=$f; break; fi
    done
    if [ -z "$COK" ] ; then
        P "RETRIEVE failed: $CARD not mountable"
    else
        mkdir -p /mnt/card/y700-out 2>/dev/null
        N=0
        for f in "$R"/var/log/y700-*.txt ; do
            [ -f "$f" ] || continue
            cat "$f" > "/mnt/card/y700-out/${f##*/}" 2>/dev/null && N=$((N + 1))
        done
        {
            echo "=== $K root state, read at switch_root time ==="
            echo "dev=$DEV up=$(cut -d . -f 1 /proc/uptime)"
            echo "-- markers --"; ls -l "$R/var/lib/y700" 2>&1
            echo "-- /var/log --"; ls -l "$R/var/log" 2>&1 | head -30
            echo "-- autologin --"; ls -l "$R/etc/sddm.conf.d" 2>&1
            for f in "$R"/etc/sddm.conf.d/*.conf; do [ -f "$f" ] && { echo "== $f"; cat "$f" 2>&1; }; done
            echo "-- y700 units --"; ls -l "$R/etc/systemd/system" 2>&1 | grep -a y700
            echo "-- masked --"; for f in "$R"/etc/systemd/system/*; do [ -L "$f" ] && [ "$(readlink "$f")" = "/dev/null" ] && echo "MASKED ${f##*/}"; done
            echo "-- filesystem --"; df -k "$R" 2>&1
            echo "-- root size --"; cat /sys/block/sda/sda16/size 2>/dev/null
        } > /mnt/card/y700-out/a108-rootstate.txt 2>&1
        busybox sync
        P "RETRIEVE files=$N fs=$COK dest=$(ls /mnt/card/y700-out 2>/dev/null | busybox tr '\n' ' ')"
        umount /mnt/card 2>/dev/null
        busybox sync
    fi
fi

if [ -e "$DONE" ] ; then
    P "already applied ($(cat "$DONE" 2>/dev/null)), nothing to do"
    exit 0
fi
echo "=== $K patch up=$(cut -d . -f 1 /proc/uptime) dev=$DEV root=$R ===" > "$LOG" 2>/dev/null

# ---- 2. SDDM autologin straight into Plasma Mobile ----
if [ ! -f "$R/usr/lib/systemd/system/sddm.service" ] ; then
    P "NO sddm.service in the root - leaving the weston session alone"
    U "ABORT no sddm.service"
    exit 1
fi
mkdir -p "$R/etc/sddm.conf.d" "$R/etc/systemd/system/graphical.target.wants" "$R/etc/systemd/system/multi-user.target.wants" 2>/dev/null
printf "[Autologin]\nUser=armada\nSession=armada-plasma-mobile.desktop\nRelogin=true\n" > "$R/etc/sddm.conf.d/zz-y700-autologin.conf"
U "autologin=$(tr '\n' ';' < "$R/etc/sddm.conf.d/zz-y700-autologin.conf")"
ln -sf /dev/null "$R/etc/systemd/system/armada-session-default.service"
U "armada-session-default masked (it rewrites autologin to Game Mode every boot)"
# The ESP is an Android partition on this board; these two units write /KERNEL
# and rename that partition.  Neither is allowed to run from a UFS root.
for u in armada-bootimg-sync armada-esp-rename; do
    ln -sf /dev/null "$R/etc/systemd/system/$u.service"
    U "$u masked (ESP writes would touch Android)"
done
if [ -L "$R/etc/systemd/system/sddm.service" ] && [ "$(readlink "$R/etc/systemd/system/sddm.service")" = "/dev/null" ] ; then
    rm -f "$R/etc/systemd/system/sddm.service"
    U "unmasked sddm.service"
fi
# The wants link has to be ABSOLUTE.  A relative "../sddm.service" resolves to
# /etc/systemd/system/sddm.service, where nothing exists unless the unit is
# masked - that dangling link is exactly why A107 never started sddm at all.
ln -sf /usr/lib/systemd/system/sddm.service "$R/etc/systemd/system/graphical.target.wants/sddm.service"
# Shipwrecked by its own rate limit otherwise: three failed sessions and the
# display manager stays dead for the rest of the boot.
mkdir -p "$R/etc/systemd/system/sddm.service.d" 2>/dev/null
cat > "$R/etc/systemd/system/sddm.service.d/y700.conf" <<'SU'
[Unit]
StartLimitIntervalSec=0
SU
if [ -e "$R/etc/systemd/system/graphical.target.wants/sddm.service" ] ; then
    U "sddm wanted by graphical.target via $(readlink "$R/etc/systemd/system/graphical.target.wants/sddm.service"), start limit removed"
else
    P "WANTS_LINK_BROKEN $(readlink "$R/etc/systemd/system/graphical.target.wants/sddm.service")"
    U "wants link dangling"
fi

# ---- 3. the weston session must not fight it for the DRM master ----
rm -f "$R/etc/systemd/system/multi-user.target.wants/y700-desktop.service"
U "y700-desktop.service kept but not wanted (fallback only)"

# ---- 4. grow the Linux root into the rest of p16, once ----
cat > "$R/etc/systemd/system/y700-resize.service" <<'RU'
[Unit]
Description=Y700 grow the Linux root filesystem into its own UFS partition
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

# ---- 5. one diagnostic pass per boot: journal + card copy + weston fallback ----
mkdir -p "$R/usr/local/bin" 2>/dev/null
cat > "$R/usr/local/bin/y700-diag.sh" <<'DIAG'
#!/bin/sh
# A108: single-shot evidence collection inside the running system.
# The panel is fbcon only while no compositor owns the display, so the log has
# to leave the device: it goes to the SD card when one is inserted, and the
# initramfs copies it out on the next boot either way.
K="Y700-A108-DIAG"
OUT=/var/log/y700-diag.txt
P() { echo "<3>$K $*"; }
{
    echo "=== $K up=$(cut -d ' ' -f 1 /proc/uptime) ==="
    echo "-- is-active --"
    for u in sddm display-manager graphical.target multi-user.target y700-resize armada-splash-early; do
        printf '%s=%s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
    done
    echo "-- failed units --"
    systemctl list-units --state=failed --no-legend --plain 2>&1
    echo "-- sddm --"
    systemctl status sddm --no-pager -l 2>&1 | head -40
    echo "-- autologin in effect --"
    cat /etc/sddm.conf.d/*.conf 2>&1
    echo "-- sddm state --"
    cat /var/lib/sddm/state.conf 2>&1
    ls -l /var/lib/sddm 2>&1
    echo "-- logind --"
    loginctl list-sessions 2>&1
    loginctl list-users 2>&1
    echo "-- drm --"
    ls -l /dev/dri 2>&1
    ls -l /sys/class/drm 2>&1
    echo "-- vtconsoles --"
    for c in /sys/class/vtconsole/vtcon*; do [ -d "$c" ] && echo "$(basename $c) name=$(cat $c/name 2>/dev/null) bind=$(cat $c/bind 2>/dev/null)"; done
    echo "-- graphics processes --"
    ps -eo pid,user,etime,comm 2>&1 | grep -aiE 'sddm|kwin|plasma|weston|gamescope|weston' 
    echo "-- session logs --"
    for f in /var/home/armada/.cache/wayland-errors /var/home/armada/.cache/xsession-errors /root/.cache/wayland-errors; do
        [ -f "$f" ] && { echo "== $f"; tail -n 60 "$f"; }
    done
    echo "-- filesystem --"
    df -h / 2>&1
    ls -l /var/lib/y700 2>&1
    systemctl status y700-resize --no-pager -l 2>&1 | head -25
    echo "-- journal, display related --"
    journalctl -b --no-pager 2>&1 | grep -aiE 'sddm|plasma|kwin|wayland|greeter|drm|segfault|coredump|oom' | tail -n 150
    echo "-- journal, last 80 --"
    journalctl -b --no-pager 2>&1 | tail -n 80
} > "$OUT" 2>&1

P "state $(for u in sddm display-manager graphical.target; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done)"
P "failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l) sessions=$(loginctl list-sessions --no-legend --plain 2>/dev/null | grep -c .) df=$(df -h / 2>/dev/null | awk 'NR==2{print $2"/"$3}')"
P "log=$OUT lines=$(grep -c . "$OUT" 2>/dev/null)"

C=$(readlink -f /dev/disk/by-label/ARMADA 2>/dev/null)
case "$C" in
    /dev/mmcblk*)
        mkdir -p /mnt/y700card 2>/dev/null
        if mount -t vfat -o rw "$C" /mnt/y700card 2>/dev/null ; then
            mkdir -p /mnt/y700card/y700-out 2>/dev/null
            cat "$OUT" > /mnt/y700card/y700-out/y700-diag.txt 2>/dev/null
            journalctl -b --no-pager 2>&1 | tail -n 400 > /mnt/y700card/y700-out/y700-journal.txt 2>/dev/null
            sync
            umount /mnt/y700card 2>/dev/null
            P "CARD_COPY ok dev=$C"
        else
            P "CARD_COPY mount failed dev=$C"
        fi
        ;;
    *)
        P "CARD_COPY skipped (label ARMADA resolves to [$C])"
        ;;
esac

if ! systemctl is-active --quiet sddm ; then
    sleep 5
    if ! systemctl is-active --quiet sddm ; then
        if [ -e /etc/systemd/system/y700-desktop.service ] ; then
            P "FALLBACK sddm is dead, starting the weston session"
            systemctl start y700-desktop.service 2>&1 | head -n 3
        else
            P "FALLBACK no y700-desktop.service to fall back to"
        fi
    fi
fi
DIAG
cat > "$R/etc/systemd/system/y700-diag.service" <<'DU'
[Unit]
Description=Y700 A108 session diagnostics
After=multi-user.target
Wants=systemd-journald.service

[Service]
Type=oneshot
# Long enough for sddm to start, crash and hit its rate limit at least twice.
ExecStartPre=-/usr/bin/sleep 55
ExecStart=/usr/local/bin/y700-diag.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
DU
ln -sf ../y700-diag.service "$R/etc/systemd/system/multi-user.target.wants/y700-diag.service"
U "y700-diag.service armed"

# ---- 6. trace on the panel console ----
P "plasma-mobile armed session=$(sed -n 's/^Session=//p' "$R/etc/sddm.conf.d/zz-y700-autologin.conf" 2>/dev/null) user=$(sed -n 's/^User=//p' "$R/etc/sddm.conf.d/zz-y700-autologin.conf" 2>/dev/null)"
P "resize armed p16sectors=$(cat /sys/block/sda/sda16/size 2>/dev/null)"
echo "$K applied up=$(cut -d . -f 1 /proc/uptime)" > "$DONE" 2>/dev/null
P "A108 APPLIED"
exit 0
