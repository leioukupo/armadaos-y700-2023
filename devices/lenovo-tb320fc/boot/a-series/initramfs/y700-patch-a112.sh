#!/bin/sh
# A110: take the evidence out of the installed root, then arm Plasma Mobile.
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
#    "Y700-HB" log scroll that was reported.  A110 removes that start limit,
#    installs a diagnostic unit that journals the session state (to the card as
#    well), keeps a weston fallback so the panel is never dead, and masks the
#    two distro units that write to the EFI System Partition - on this board the
#    ESP is an Android partition, and /KERNEL on it is what ABL loads.
# A112 = A111 plus one thing: the PREVIOUS boot's kernel console.  The DTB
# carries ramoops@f0000000 (record 16k, console 1.75M, pmsg 16k) and the kernel
# has PSTORE_CONSOLE/PSTORE_RAM, so a boot that died - the A111 boot never
# reached its own patch hook, and "looks like a kernel panic" was reported -
# leaves its last 1.75 MB of dmesg in RAM.  Reading /pstore is one-shot, so the
# files are pulled into ram first and then written to the card.
#
# A111 = A110, three fixes about SEEING what a round did:
#   * the patch log lands on the card in its OWN boot.  A107/A108 only showed up
#     one boot late (the log is created after the retrieve pass) and A109's never
#     showed at all, so the round under test was never readable while it was the
#     round that was running - six boots without a verdict on the sddm wants link.
#   * the in-root diagnostic resolved the card only through
#     /dev/disk/by-label/ARMADA and printed nothing when that symlink was absent.
#     It now scans every mmcblk partition for the y700-out directory and reports,
#     on the panel, which block devices and mmc hosts it could see instead.
#   * a one-line state summary repeats on the panel console every 15 s
#     (Y700-A111-DIAG SUM ...), so sddm / session processes / failed-unit count /
#     drm nodes are readable with no card in the slot at all.
#
# A110 = A109 with two fixes that A109 could not reveal about itself:
#   * the diagnostic script was written 0644, so systemd answered every
#     attempt with status=203/EXEC and no round ever produced evidence
#   * the journal copy is now budgeted; A109's 285 MB tar overran the FAT
#     and left the card looking hardware-broken
#
# Carried over from A109 (all of it about seeing what userspace did):
#   * the persistent journal (/var/log/journal really exists on this root) is
#     tarred onto the card, so journalctl can be run offline on the dev board
#   * sddm state and the session wayland-errors are copied out directly
#   * the weston fallback unit + script are copied out, to compare against
#   * every wants symlink is resolved and dangling ones reported by name
#   * the diagnostic pass runs twice (t+0 and t+45) and pushes to the card each
#     time, so a reset part-way through still leaves evidence
DEV=$1
R=$2
CARD=$3
K="Y700-A112"
P() { echo "<3>$K $*"; }
LOG="$R/var/log/y700-a112.txt"
DONE="$R/var/lib/y700/a112.done"
U() { echo "$*" >> "$LOG" 2>/dev/null; }

[ -n "$R" ] || { P "REFUSE no root mountpoint"; exit 1; }
[ -d "$R/usr/lib/systemd/system" ] || { P "REFUSE $R is not the Armada root"; exit 1; }
mkdir -p "$R/var/log" "$R/var/lib/y700" "$R/etc/systemd/system" 2>/dev/null
P "patch start dev=$DEV card=[$CARD] up=$(cut -d . -f 1 /proc/uptime)"

# ---- 0. the previous boot died somewhere we could not see; ramoops kept it ----
mkdir -p /pstore 2>/dev/null
if mount -t pstore pstore /pstore 2>/dev/null ; then
    for f in /pstore/*; do
        [ -f "$f" ] || continue
        cat "$f" > "/pstore-${f##*/}.txt" 2>/dev/null
    done
    umount /pstore 2>/dev/null
    for f in /pstore-console*.txt /pstore-dmesg*.txt /pstore-pmsg*.txt; do
        [ -f "$f" ] || continue
        P "PSTORE $(basename "$f") bytes=$(wc -c < "$f" 2>/dev/null) panic_hits=$(grep -aicE "kernel panic|Unable to handle|Oops:|Internal error|Call trace|out of memory|Watchdog" "$f" 2>/dev/null) last=[$(grep -aE "kernel panic|Unable to handle|Oops:|Internal error|Watchdog|Out of memory" "$f" 2>/dev/null | tail -n 1 | cut -c 1-160)]"
    done
    P "PSTORE files=[$(ls /pstore-*.txt 2>/dev/null | busybox tr "\n" " ")]"
else
    P "PSTORE no pstore mount (ramoops absent?)"
fi

# ---- 1. evidence: root -> SD card, before anything new is written ----
case "$CARD" in
    /dev/mmcblk*) ;;
    *) CARD="" ;;
esac
if [ -z "$CARD" ] ; then
    # /init only gives the card five seconds at the very start of boot, and this
    # controller has often taken longer than that (the heartbeat sat on
    # 8804000.mmc for a while).  A round with no card cannot report anything, so
    # look for the card again here, from the patch, where more time has passed.
    _n=0
    while [ $_n -lt 12 ] ; do
        _n=$((_n + 1))
        for d in /dev/mmcblk*p[0-9] ; do
            [ -b "$d" ] || continue
            mkdir -p /mnt/cardprobe 2>/dev/null
            if mount -t vfat -o ro "$d" /mnt/cardprobe 2>/dev/null ; then
                umount /mnt/cardprobe 2>/dev/null
                CARD="$d"
                break
            fi
        done
        [ -n "$CARD" ] && break
        sleep 1
    done
    P "CARD rescan=${_n} found=[$CARD] blocks=[$(ls /dev/mmcblk* 2>/dev/null | busybox tr "\n" " ")]"
fi
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
            echo "-- wants, resolved --"
            for d in graphical multi-user; do
                WD="$R/etc/systemd/system/$d.target.wants"
                ls "$WD" >/dev/null 2>&1 || { echo "no $d.target.wants directory"; continue; }
                for l in "$WD"/*; do
                    [ -L "$l" ] || continue
                    T=$(readlink "$l")
                    case "$T" in
                        /*) X="$R$T" ;;
                        *)  X="$(dirname "$l")/$T" ;;
                    esac
                    if [ -e "$X" ] ; then echo "ok $d ${l##*/} -> $T"; else echo "DANGLING $d ${l##*/} -> $T"; fi
                done
            done
            echo "-- sddm state / session log --"
            cat "$R/var/lib/sddm/state.conf" 2>&1
            for f in "$R"/var/home/armada/.cache/wayland-errors "$R"/var/home/armada/.cache/xsession-errors; do
                [ -f "$f" ] && { echo "== $f"; tail -n 80 "$f"; }
            done
        } > /mnt/card/y700-out/a110-rootstate.txt 2>&1
        busybox sync
        busybox sync
        # The journal is persistent here, and it is the only record of what systemd
        # did.  A109 tried to tar the whole thing: 285 MB into a 501 MB FAT, the write
        # ran out of space and dosfsck later found "invalid cluster chain" with files
        # truncated to zero - that is how a healthy card looks broken.  So: drop the
        # old archive first, size the budget from the free space that is actually
        # there, and copy the newest files only, keeping the <machine-id>/ layout so
        # journalctl -D can read the directory offline.
        rm -f /mnt/card/y700-out/journal.tar 2>/dev/null
        rm -rf /mnt/card/y700-out/journal 2>/dev/null
        FREE=$(df -k /mnt/card 2>/dev/null | busybox tail -1 | awk '{print $4}')
        [ -n "$FREE" ] || FREE=0
        BUDGET=$((FREE / 4))
        [ $BUDGET -gt 40960 ] && BUDGET=40960
        ACC=0
        JJ=0
        for j in $(ls -t "$R"/var/log/journal/*/*.journal 2>/dev/null) ; do
            [ -f "$j" ] || continue
            SZ=$(( $(wc -c < "$j" 2>/dev/null || echo 0) / 1024 ))
            [ $((ACC + SZ)) -le "$BUDGET" ] || break
            MID=$(basename "$(dirname "$j")")
            mkdir -p "/mnt/card/y700-out/journal/$MID" 2>/dev/null
            if cat "$j" > "/mnt/card/y700-out/journal/$MID/${j##*/}" 2>/dev/null ; then
                JJ=$((JJ + 1)); ACC=$((ACC + SZ))
            else
                P "JOURNAL write failed at ${j##*/} after ${ACC}kb"
                break
            fi
        done
        P "JOURNAL files=$JJ kb=$ACC budget=$BUDGET free=$FREE"
        busybox sync
        # The previous boot's dmesg: only the tail matters, and the FAT is 501 MB.
        for f in /pstore-*.txt; do
            [ -f "$f" ] || continue
            tail -c 400000 "$f" > "/mnt/card/y700-out/${f##*/}" 2>/dev/null
            P "PSTORE saved $(basename "$f")"
        done
        busybox sync
        # These are small and answer the question even without a journal parser.
        for f in var/lib/sddm/state.conf var/home/armada/.cache/wayland-errors var/home/armada/.cache/xsession-errors var/home/armada/.local/share/sddm/wayland-session.log var/home/armada/.local/share/sddm/xorg-session.log etc/systemd/system/y700-desktop.service usr/local/bin/y700-desktop.sh; do
            [ -f "$R/$f" ] || continue
            cat "$R/$f" > "/mnt/card/y700-out/$(echo "$f" | busybox tr '/' '_')" 2>/dev/null
        done
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
WL="$R/etc/systemd/system/graphical.target.wants/sddm.service"
if [ -L "$WL" ] && [ -e "$R$(readlink "$WL")" ] ; then
    U "sddm wanted by graphical.target via $(readlink "$WL") -> $R$(readlink "$WL"), start limit removed"
else
    P "WANTS_LINK_BROKEN link=$(readlink "$WL") resolves_to=$R$(readlink "$WL")"
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
# A110: evidence collection inside the running system, twice per boot.
# The panel shows fbcon only while no compositor owns the display, and a reset
# can come before one late pass would run, so each pass is pushed to the card
# as soon as it is written.
K="Y700-A112-DIAG"
P() { echo "<3>$K $*"; }

collect() {
    OUT="$1"
    {
        echo "=== $K pass=$2 up=$(cut -d ' ' -f 1 /proc/uptime) ==="
        echo "-- is-active --"
        for u in sddm display-manager graphical.target multi-user.target y700-resize y700-diag; do
            printf '%s=%s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
        done
        echo "-- failed units --"
        systemctl list-units --state=failed --no-legend --plain 2>&1
        echo "-- sddm --"
        systemctl status sddm --no-pager -l 2>&1 | head -n 40
        ls -l /run/sddm* /var/lib/sddm 2>&1
        cat /var/lib/sddm/state.conf 2>&1
        echo "-- autologin in effect --"
        cat /etc/sddm.conf.d/*.conf 2>&1
        echo "-- logind --"
        loginctl list-sessions 2>&1
        loginctl list-users 2>&1
        loginctl seat-status seat0 2>&1 | head -n 30
        echo "-- drm / vt --"
        ls -l /dev/dri /sys/class/drm 2>&1
        for c in /sys/class/vtconsole/vtcon*; do
            [ -d "$c" ] && echo "$(basename "$c") name=$(cat "$c/name" 2>/dev/null) bind=$(cat "$c/bind" 2>/dev/null)"
        done
        echo "-- who holds a drm node --"
        for p in /proc/[0-9]*; do
            for f in "$p"/fd/*; do
                t=$(readlink "$f" 2>/dev/null) || continue
                case "$t" in /dev/dri/*) echo "$(cat "$p"/comm 2>/dev/null) pid=${p#/proc/} $t";; esac
            done
        done 2>/dev/null | head -n 30
        echo "-- graphics processes --"
        ps -eo pid,user,etime,cmd 2>&1 | grep -aiE 'sddm|kwin|plasma|weston|gamescope' | grep -v grep
        echo "-- session logs --"
        for f in /var/home/armada/.cache/wayland-errors /var/home/armada/.cache/xsession-errors /var/home/armada/.local/share/sddm/wayland-session.log /var/home/armada/.local/share/sddm/xorg-session.log /root/.cache/wayland-errors; do
            [ -f "$f" ] && { echo "== $f"; tail -n 80 "$f"; }
        done
        ls -lR /var/home/armada/.local/share/sddm /run/sddm* 2>&1
        echo "-- sddm journal, whole boot --"
        journalctl -b -u sddm --no-pager 2>&1 | tail -n 120
        echo "-- priority>=err, whole boot --"
        journalctl -b -p 3 --no-pager 2>&1 | tail -n 80
        echo "-- filesystem --"
        df -h / 2>&1
        ls -l /var/lib/y700 2>&1 | head -n 20
        echo "-- systemd analysis --"
        systemd-analyze 2>&1 | head -n 5
        systemd-analyze blame 2>&1 | head -n 15
        echo "-- journal, display related --"
        journalctl -b --no-pager 2>&1 | grep -aiE 'sddm|plasma|kwin|wayland|greeter|drm|segfault|coredump|oom|abort|fail' | tail -n 200
        echo "-- journal, last 100 --"
        journalctl -b --no-pager 2>&1 | tail -n 100
    } > "$OUT" 2>&1
}


summary() {
    # One line, on the kernel console, repeated.  The panel is the only display
    # that is guaranteed to work, so the state has to be readable as text.
    S=""
    for u in sddm display-manager graphical.target; do
        S="$S $u=$(systemctl is-active "$u" 2>/dev/null)"
    done
    # /proc, not ps: the image is not guaranteed to ship procps.
    PROCS=$(for q in /proc/[0-9]*; do cat "$q/comm" 2>/dev/null; done | grep -aiE 'sddm|kwin|plasma|weston|gamescope' | sort -u | tr '\n' ',')
    P "SUM$S procs=[$PROCS] failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | grep -c .) vtbind=$(cat /sys/class/vtconsole/vtcon1/bind 2>/dev/null) dri=[$(ls /dev/dri 2>/dev/null | tr '\n' ',')] sess=$(loginctl list-sessions --no-legend --plain 2>/dev/null | grep -c .)"
}

tocard() {
    # Find the card by what is on it, not by a udev label that may not exist.
    WANT="$1"
    C=""
    mkdir -p /mnt/y700card 2>/dev/null
    for d in /dev/disk/by-label/ARMADA /dev/mmcblk*p[0-9]; do
        d=$(readlink -f "$d" 2>/dev/null)
        case "$d" in
            /dev/mmcblk*) [ -b "$d" ] || continue ;;
            *) continue ;;
        esac
        umount /mnt/y700card 2>/dev/null
        mount -t vfat -o rw "$d" /mnt/y700card 2>/dev/null || continue
        if [ -d /mnt/y700card/y700-out ] ; then C="$d"; break; fi
        umount /mnt/y700card 2>/dev/null
    done
    if [ -z "$C" ] ; then
        umount /mnt/y700card 2>/dev/null
        P "CARD_COPY no y700-out on any mmcblk partition; blocks=[$(ls /sys/block 2>/dev/null | tr '\n' ',')] mmc=[$(ls /sys/class/mmc_host 2>/dev/null | tr '\n' ',')]"
        return 1
    fi
    mkdir -p /mnt/y700card/y700-out 2>/dev/null
    cat "$WANT" > "/mnt/y700card/y700-out/${WANT##*/}" 2>/dev/null
    journalctl -b --no-pager 2>&1 | tail -n 600 > /mnt/y700card/y700-out/y700-journal.txt 2>/dev/null
    journalctl -b -u sddm -u y700-diag -u y700-desktop --no-pager 2>&1 | tail -n 300 > /mnt/y700card/y700-out/y700-sddm.txt 2>/dev/null
    sync
    sync
    umount /mnt/y700card 2>/dev/null
    P "CARD_COPY ok dev=$C file=${WANT##*/} bytes=$(wc -c < "$WANT" 2>/dev/null)"
}

# ---- session state, the panel summary, then a second pass ----
collect /var/log/y700-diag.txt early
P "early $(for u in sddm display-manager graphical.target; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done)"
tocard /var/log/y700-diag.txt

# A display manager that is not running is the one failure this board has a
# known-good answer for, so act on it before the summary loop, not after it.
if ! systemctl is-active --quiet sddm ; then
    sleep 5
    if ! systemctl is-active --quiet sddm ; then
        if [ -e /etc/systemd/system/y700-desktop.service ] ; then
            P "FALLBACK sddm is dead, starting the weston session"
            systemctl start y700-desktop.service 2>&1 | head -n 3
            P "A112 WESTON-FALLBACK issued"
        else
            P "FALLBACK no y700-desktop.service to fall back to"
        fi
    fi
fi

I=0
while [ $I -lt 8 ] ; do
    summary
    I=$((I + 1))
    sleep 15
done

collect /var/log/y700-diag2.txt late
P "late $(for u in sddm display-manager graphical.target; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done) failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | grep -c .) sessions=$(loginctl list-sessions --no-legend --plain 2>/dev/null | grep -c .) df=$(df -h / 2>/dev/null | awk 'NR==2{print $2"/"$3}')"
tocard /var/log/y700-diag2.txt
DIAG
chmod 0755 "$R/usr/local/bin/y700-diag.sh"
U "y700-diag.sh mode=$(stat -c %a "$R/usr/local/bin/y700-diag.sh" 2>/dev/null)"
cat > "$R/etc/systemd/system/y700-diag.service" <<'DU'
[Unit]
Description=Y700 A110 session diagnostics
After=multi-user.target
Wants=systemd-journald.service

[Service]
Type=oneshot
# The script takes two passes itself (right away, then 45 s later), so evidence
# reaches the card early instead of at one fixed late moment.
ExecStart=/usr/local/bin/y700-diag.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
DU
ln -sf ../y700-diag.service "$R/etc/systemd/system/multi-user.target.wants/y700-diag.service"
U "y700-diag.service armed"

# ---- 6a. the patch log itself, in the SAME boot ----
# Without this the round under test can only be read one boot later, and a boot
# that overruns the card loses the log completely - that is how A109 went blind.
if [ -n "$CARD" ] ; then
    mkdir -p /mnt/card2 2>/dev/null
    if mount -o rw "$CARD" /mnt/card2 2>/dev/null ; then
        mkdir -p /mnt/card2/y700-out 2>/dev/null
        if cat "$LOG" > /mnt/card2/y700-out/y700-a112.txt 2>/dev/null ; then
            P "PATCHLOG on card ok bytes=$(wc -c < "$LOG" 2>/dev/null)"
        else
            P "PATCHLOG write failed card=$CARD"
        fi
        busybox sync
        busybox sync
        umount /mnt/card2 2>/dev/null
    else
        P "PATCHLOG mount failed card=$CARD"
    fi
else
    P "PATCHLOG skipped: no card this boot"
fi

# ---- 6b. trace on the panel console ----
P "plasma-mobile armed session=$(sed -n 's/^Session=//p' "$R/etc/sddm.conf.d/zz-y700-autologin.conf" 2>/dev/null) user=$(sed -n 's/^User=//p' "$R/etc/sddm.conf.d/zz-y700-autologin.conf" 2>/dev/null)"
P "resize armed p16sectors=$(cat /sys/block/sda/sda16/size 2>/dev/null)"
echo "$K applied up=$(cut -d . -f 1 /proc/uptime)" > "$DONE" 2>/dev/null
P "A112 APPLIED"
exit 0
