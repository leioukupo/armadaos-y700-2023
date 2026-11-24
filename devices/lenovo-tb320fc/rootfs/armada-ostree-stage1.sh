#!/bin/sh
# stage-1: compose the OSTree deployment into the running root, then exec init.
#
# The Gen 2 board boots a flat UFS root: the boot_a initramfs mounts that root,
# picks the first executable of /init, /sbin/init, /usr/lib/systemd/systemd and
# switch_roots into it. This script is that /init. It turns the very same
# filesystem into the tree ostree-prepare-root would have built - / is the
# deployment, /sysroot is the physical root, /run is a fresh tmpfs holding the
# booted record - and then execs the distro init.
#
# Nothing here needs a new boot payload, and nothing here can eat the boot:
# every check runs before any mount moves, and every failure path execs the
# plain distro init on the flat root instead.
#
# Kill switch: /etc/armada/ostree-boot has to contain "yes".
set -u

TAG=armada-ostree-stage1
# Runtime state and the on-root log live on the physical root. There is no serial
# console and nothing outside UFS can read this partition, so armada-ostree/boot.log
# is the only witness when a composed boot dies before systemd-journald starts; it is
# rotated at 64 KiB and covers the flat and the composed path alike.
state=/armada-ostree
logf=$state/boot.log

# The boot initramfs moves /dev, /proc and /sys into the root with MS_MOVE, and on
# this board that move does not always happen - systemd mounts them itself later, so
# only stage-1's own bookkeeping notices. Everything below needs them: /proc/uptime
# for the timestamps in the log, and /proc/sysrq-trigger for the flush and the
# force-reboot that make an unrecoverable-looking boot recoverable. Errors are
# dropped because "already mounted" is the normal case.
mount -t devtmpfs dev /dev 2>/dev/null
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mkdir -p "$state" 2>/dev/null
if [ -f "$logf" ] && [ "$(wc -c < "$logf" 2>/dev/null)" -gt 65536 ]; then
    tail -c 32768 "$logf" > "$logf.tmp" 2>/dev/null && mv "$logf.tmp" "$logf" 2>/dev/null
fi
log() {
    # /proc/uptime with the shell: the early root has no coreutils cut here, and a
    # missing helper must never lose the line that explains a boot failure.
    up=
    read -r up _ < /proc/uptime 2>/dev/null
    printf '%s %s up=%s\n' "$TAG:" "$*" "$up" >>"$logf" 2>/dev/null
    echo "$TAG: $*" >>/dev/kmsg 2>/dev/null
    echo "$TAG: $*" >&2
}

# Nothing outside this UFS root can read the log, and the only way out of a
# board that never answers is a forced power cut, so every milestone has to
# reach the platter before it is announced. The sync binary is not reliable here
# (this shell starts life in the initramfs, and the distro root is only half
# resolved while it is being composed), so the kernel's own sysrq "s" is the
# primary route. Enabling sysrq means writing to /proc/sys/kernel/sysrq; writing
# "1" to /proc/sysrq-trigger is an *operation* and never enables anything.
flush() {
    echo 1 >/proc/sys/kernel/sysrq 2>/dev/null
    echo s >/proc/sysrq-trigger 2>/dev/null
    for b in /usr/bin/sync /bin/sync /sbin/sync; do
        if [ -x "$b" ]; then
            "$b" 2>/dev/null && return 0
        fi
    done
    sync 2>/dev/null
}

# PID 1 is this script and systemd was deliberately never started, so nothing
# else can restart the board. sysrq "b" is the only primitive that cannot fail.
hard_reboot() {
    flush
    flush
    echo 1 >/proc/sys/kernel/sysrq 2>/dev/null
    echo b >/proc/sysrq-trigger 2>/dev/null
    for b in /usr/bin/reboot /sbin/reboot; do
        [ -x "$b" ] && "$b" -f 2>/dev/null
    done
    echo b >/proc/sysrq-trigger 2>/dev/null
    flush
}

fallback() {
    log "FALLBACK $* - staying on the flat root"
    # Whatever was composed for the attempt is dropped again: leaving
    # /ostree/.stage1-root mounted (with /var, /etc, /opt and /usr/local bind
    # mounts under it) would shadow part of the deployment inside the running
    # flat system, and the next composition would start from that mess.
    for m in usr/local var etc opt boot run sysroot dev proc sys; do
        umount -l "/ostree/.stage1-root/$m" 2>/dev/null
    done
    umount -l /ostree/.stage1-root 2>/dev/null
    rmdir /ostree/.stage1-root 2>/dev/null
    # A flat boot is not an attempted composed boot; leaving the record behind
    # would make the next boot count a failure that never happened.
    rm -f /armada-ostree/attempt 2>/dev/null
    for cand in /sbin/init /usr/lib/systemd/systemd; do
        if [ -x "$cand" ]; then
            exec "$cand" "$@"
        fi
    done
    exec /bin/sh
}

# Little-endian 64-bit, as octal printf escapes (shell arithmetic is 64 bit).
le64() {
    v=$1
    fmt=
    i=0
    while [ "$i" -lt 8 ]; do
        b=$(( (v >> (8 * i)) & 0xff ))
        fmt="$fmt\\$(printf '%03o' "$b")"
        i=$((i + 1))
    done
    # shellcheck disable=SC2059
    printf "$fmt"
}

# /run/ostree-booted is a GVariant a{sv} with one entry:
# "backing-root-device-inode" -> (tt), the st_dev/st_ino of the deployment
# directory. GLib serialises that in 55 bytes: the key with its NUL, padded to 8
# (32), the two u64s (16), then the value's type string and a one byte offset
# table (26, 54). This is byte for byte what g_variant_new() produces, which
# matters because libostree reads the file as a *trusted* variant: a malformed
# record does not fail cleanly, it segfaults the caller.
write_booted() {
    dep=$1
    out=$2
    set -- $(stat -c '%d %i' "$dep" 2>/dev/null) || return 1
    [ "$#" = 2 ] || return 1
    {
        printf 'backing-root-device-inode\000\000\000\000\000\000\000'
        le64 "$1"
        le64 "$2"
        printf '\000(tt)\032\066'
    } > "$out" 2>/dev/null || return 1
    [ "$(wc -c < "$out")" = 55 ] || return 1
    log "booted record dev=$1 ino=$2 at $out"
    return 0
}

# ---- what a dry run reports -----------------------------------------------
# Written from inside the composed tree, so every line is what systemd and
# bootc would see on the next real boot: which filesystem backs /run, whether a
# stale journal is sitting in it, which .mount units and fstab entries the
# deployment carries, and how the ostree links resolve once / is the deployment.
dryrun_report() {
    out=$1
    {
        echo "armada-ostree dry run up=$(cut -d ' ' -f1 /proc/uptime)"
        echo "root=$(stat -c '%d:%i' /) init=$init"
        echo "-- mountinfo"
        cat /proc/self/mountinfo
        echo "-- filesystem behind each directory"
        for p in / /run /run/log /etc /var /var/log /boot /sysroot; do
            printf '%s ' "$p"
            stat -f -c '%T blocks=%c free=%a' "$p" 2>&1
        done
        echo "-- /run contents"
        ls -la /run 2>&1
        ls -laR /run/log 2>&1
        echo "-- journal files reachable from the composed root"
        find /run/log/journal /var/log/journal -name '*.journal' -printf '%s %p\n' 2>&1
        echo "-- machine-id"
        cat /etc/machine-id 2>&1
        echo "-- mount units shipped by the image"
        ls /usr/lib/systemd/system 2>&1 | grep '\.mount$'
        echo "-- mount units and overrides in /etc"
        ls -la /etc/systemd/system 2>&1 | grep '\.mount'
        echo "-- fstab"
        cat /etc/fstab 2>&1
        echo "-- init candidates in the deployment"
        ls -la /init /sbin/init /usr/lib/systemd/systemd 2>&1
        echo "-- os-release"
        head -8 /usr/lib/os-release 2>&1
        echo "-- ostree links as seen from the composed root"
        ls -la /ostree 2>&1 | head -8
        readlink -f /ostree/boot.1 2>&1
        echo "-- systemd units the deployment enables"
        ls /usr/lib/systemd/system/basic.target.wants 2>&1 | head -20
        ls /etc/systemd/system/multi-user.target.wants 2>&1 | head -20
    } >"$out" 2>&1
}

# ---- gate ------------------------------------------------------------------
mount -o remount,rw / 2>/dev/null
mode=$(tr -d ' \t\r\n' < /etc/armada/ostree-boot 2>/dev/null)
log "gate marker=[$mode] root=$(stat -c '%d:%i' /) statefiles=$(ls $state 2>/dev/null | tr '\n' ' ')"
if [ "$mode" != yes ]; then
    fallback "marker /etc/armada/ostree-boot is [$mode]"
fi

# ---- composed-root dry run (opt-in) ----------------------------------------
# How a composed boot that dies before it can be reached is diagnosed. Two
# strengths, because the first one must never cost a boot:
#   $state/dryrun        probe - compose the tree, write the report, unmount
#                        everything and boot the flat root. systemd is never
#                        started, the board stays reachable and the report is
#                        readable over ssh straight afterwards.
#   $state/dryrun-pivot  pivot into the composed tree, report from inside it and
#                        hard reboot. Only when pivot_root itself is suspect.
dryrun=no
if [ -e "$state/dryrun" ]; then
    dryrun=probe
    log "dry run requested ($state/dryrun) - probe only, the flat root will boot"
fi
if [ -e "$state/dryrun-pivot" ]; then
    dryrun=pivot
    log "dry run requested ($state/dryrun-pivot) - pivot, report, reboot"
fi

# ---- arm the attempt, and undo a composed boot that never came up ----------
# This board has no TF card, no serial console and nothing that can read the UFS
# root from outside, so a composed root that dies before systemd is reached would
# be retried forever with no way back. stage-1 records the attempt on the physical
# root before it moves any mount; armada-ostree-confirm.service creates
# confirmed once the composed system is reachable. An attempt with no
# confirmation means the last composed boot died, so this one stays flat and the
# kill switch turns itself off on the spot. One strike is enough: a composed root
# that livelocks before it can be reached looks exactly like a dead board from
# outside (no serial, no TF card, ssh never answers), and recovering from that
# costs a forced power cut per attempt. Re-arming is a deliberate act instead.
if [ -e "$state/attempt" ] && [ ! -e "$state/confirmed" ]; then
    failed=$(cat "$state/failed" 2>/dev/null)
    case "$failed" in ""|*[!0-9]*) failed=0 ;; esac
    failed=$((failed + 1))
    mkdir -p "$state" 2>/dev/null
    printf '%s\n' "$failed" > "$state/failed" 2>/dev/null
    mkdir -p /etc/armada 2>/dev/null
    printf 'no\n' > /etc/armada/ostree-boot 2>/dev/null
    fallback "the composed boot was never confirmed (failed=$failed) - marker set to no, re-arm with: echo yes > /etc/armada/ostree-boot"
fi
if ! mkdir -p "$state" 2>/dev/null || ! printf 'stage1\n' > "$state/attempt" 2>/dev/null; then
    fallback "cannot record the attempt in $state"
fi
flush
rm -f "$state/confirmed" 2>/dev/null

# ---- which deployment ------------------------------------------------------
# libostree reads its deployment list from the bootloader specs in
# /boot/loader.N/entries/ostree-*.conf: every entry carries an
# ostree=/ostree/boot.B/<stateroot>/<bootcsum>/<treebootserial> karg, and that
# path is a symlink whose target basename is "<csum>.<serial>". The entry with
# the highest version is what "ostree admin status" calls the default, so the
# serial picks the same tree bootc and ostree would boot - and an
# "ostree admin rollback" rewrites those entries, which the serial then follows.
#
# The mtime of the deployment tree cannot be the rule here: this board's clock
# starts a month behind and only NTP corrects it later, so a composed boot
# touches its own deployment directory with a skewed timestamp and the tree that
# is running sorts oldest on the next boot. The mtime scan survives only as the
# fallback for a root that has no bootloader specs at all.
bootversion=0
if [ -L /boot/loader ]; then
    case $(readlink /boot/loader) in
        loader.1) bootversion=1 ;;
        *) bootversion=0 ;;
    esac
fi
dep=
serial=-1
blsv=-1
newest=-1
for f in /boot/loader."$bootversion"/entries/ostree-*.conf; do
    [ -r "$f" ] || continue
    ver=$(sed -n 's/^version[ =]\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
    [ -n "$ver" ] || ver=0
    link=$(sed -n 's/.*ostree=\([^ ]*\).*/\1/p' "$f" | head -1)
    [ -n "$link" ] || continue
    d=$(readlink -f "$link" 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] || continue
    if [ "$ver" -gt "$blsv" ]; then
        blsv=$ver
        serial=${d##*.}
        [ "$serial" -eq "$serial" ] 2>/dev/null || serial=-1
        dep=$d
        log "boot loader spec $(basename "$f") version=$ver selects $d"
    fi
done
if [ -z "$dep" ]; then
    log "note: no bootloader spec for a deployment, falling back to tree mtime"
    newest=-1
    for d in /ostree/deploy/*/deploy/*.*; do
        [ -d "$d" ] || continue
        s=${d##*.}
        [ "$s" -eq "$s" ] 2>/dev/null || continue
        stamp=$(stat -c %Y "$d" 2>/dev/null)
        [ -n "$stamp" ] || stamp=0
        if [ "$stamp" -gt "$newest" ] ||
           { [ "$stamp" -eq "$newest" ] && [ "$s" -ge "$serial" ]; }; then
            newest=$stamp
            serial=$s
            dep=$d
        fi
    done
fi
[ -n "$dep" ] || fallback "no deployment under /ostree/deploy"
stateroot=${dep#*/ostree/deploy/}
stateroot=${stateroot%%/*}
log "deployment=$dep stateroot=$stateroot serial=$serial mtime=$newest"

# ---- validate before touching anything ------------------------------------
init=
for cand in "$dep/sbin/init" "$dep/usr/lib/systemd/systemd"; do
    [ -x "$cand" ] && init=${cand#$dep} && break
done
[ -n "$init" ] || fallback "no executable init in $dep"
missing=
for v in sysroot run dev proc sys tmp; do
    [ -e "$dep/$v" ] || missing="$missing $v"
done
# The ostree link points at sysroot/ostree, which only resolves once /sysroot is
# the physical root; before composition it is expected to dangle.
[ -e "$dep/ostree" ] || [ -L "$dep/ostree" ] || missing="$missing ostree"
[ -n "$missing" ] && fallback "deployment has no $missing (re-run armada-ostree-adopt)"
[ -d "/ostree/deploy/$stateroot/var" ] || fallback "no stateroot var for $stateroot"
[ -x "$dep$init" ] || fallback "init $init not executable"

# ---- compose --------------------------------------------------------------
# Private propagation first: MS_MOVE is refused on a shared subtree.
mount --make-rprivate / 2>/dev/null
new=/ostree/.stage1-root
mkdir -p "$new" 2>/dev/null || fallback "cannot create $new"
mount --bind "$dep" "$new" || fallback "bind $dep -> $new"
mount --bind / "$new/sysroot" || fallback "bind / -> $new/sysroot"

# /var, /etc, /opt and /usr/local are the state that has to be shared with the
# physical root: the NetworkManager connection for the Wi-Fi we are sitting on,
# the sshd and y700 unit enablement, the machine-id, the KDE account data under
# /var/home, and every local fix that lives under /usr/local (uhid.ko,
# cpufreq_conservative.ko, the tb320fc helpers). The deployment carries its own
# copies from the day it was adopted - its etc is already a year of Wi-Fi names
# out of date - and a composed root that used them lost its route, its sshd and
# its desktop, which the confirm step counted as a dead boot.
#
# Only real directories get bound. In a deployment, /home, /root and /srv are
# symlinks into the deployment's own var (ostree's convention), so binding them
# directly follows the link and mounts at the link's target instead of at the
# mount point stage-1 then checks; once var is bound, those three links resolve
# into the physical root by themselves and the verification pass proves it.
bound=
for m in var etc opt usr/local; do
    [ -d "/$m" ] || continue
    dst=$new/$m
    if [ -L "$dst" ]; then
        # A link inside the tree can still be bound, just not at the link.
        tgt=$(readlink -f "$dst" 2>/dev/null)
        case "$tgt" in
            "$new"/*) dst=$tgt ;;
            *) fallback "$new/$m links to [$tgt], outside the composed tree" ;;
        esac
    fi
    [ -d "$dst" ] || fallback "no directory at $dst for /$m"
    mount --bind "/$m" "$dst" || fallback "bind /$m -> $dst"
done
# A bind that silently does not take is the worst failure this script can have:
# the composed root comes up on the deployment's stale state - the machine-id of
# the day it was adopted, the Wi-Fi names that no longer exist, no route, no
# account data - and every symptom points somewhere else. Re-check every runtime
# path the way the composed root resolves it, and refuse to compose on a
# mismatch.
for m in var etc opt usr/local home root srv; do
    [ -e "/$m" ] || continue
    # -L matters: /home, /root and /srv are symlinks on both sides, and plain
    # stat() reports the link inode, which compares unequal for two links that
    # resolve to the same directory.
    src=$(stat -Lc '%d:%i' "/$m" 2>/dev/null)
    dst=$(stat -Lc '%d:%i' "$new/$m" 2>/dev/null)
    [ -n "$src" ] && [ "$src" = "$dst" ] || fallback "/$m does not resolve to the physical root (physical=$src composed=$dst)"
    bound="$bound /$m=$src"
done
log "runtime state bound from the physical root:$bound"

mount -t tmpfs -o mode=0755 tmpfs "$new/run" || fallback "tmpfs on $new/run"
if [ -d /boot ]; then
    mount --bind /boot "$new/boot" 2>/dev/null || log "note: /boot kept from the deployment"
fi
write_booted "$dep" "$new/run/ostree-booted" || fallback "cannot write the booted record"
[ -x "$new$init" ] || fallback "$init missing after composition"

# ---- probe: the composed view without moving anything ----------------------
# Everything the composed root would expose is reachable through $new, so the
# report is written before any mount moves; unmounting $new afterwards leaves
# the flat boot exactly as if the probe had never run.
probe_report() {
    out=$1
    R=$new
    for m in dev proc sys; do
        mount --bind "/$m" "$R/$m" 2>/dev/null
    done
    {
        echo "armada-ostree probe up=$(cut -d ' ' -f1 /proc/uptime)"
        echo "deployment=$dep stateroot=$stateroot serial=$serial init=$init"
        echo "-- mountinfo (major:minor mountpoint fstype)"
        awk '{print $3, $5, $6}' /proc/self/mountinfo
        echo "-- filesystem behind each composed directory"
        for p in / /run /run/log /etc /var /var/log /boot /sysroot; do
            printf '%s ' "$p"
            stat -f -c '%T blocks=%c free=%a' "$R$p" 2>&1
        done
        echo "-- composed /run contents"
        ls -la "$R/run" 2>&1
        ls -laR "$R/run/log" 2>&1
        echo "-- journal files reachable from the composed root"
        find "$R/run/log/journal" "$R/var/log/journal" -name '*.journal' -printf '%s %p\n' 2>&1
        echo "-- machine-id as the composed root sees it"
        cat "$R/etc/machine-id" 2>&1
        echo "-- flat /run (what a composed boot inherits) and its journal"
        stat -f -c '%T' /run 2>&1
        ls -la /run/log/journal 2>&1
        echo "-- init candidates in the deployment"
        ls -la "$R/init" "$R/sbin/init" "$R/usr/lib/systemd/systemd" 2>&1
        echo "-- os-release"
        head -8 "$R/usr/lib/os-release" 2>&1
        echo "-- ostree links as seen from the composed root"
        ls -la "$R/ostree" 2>&1 | head -8
        readlink -f "$R/ostree/boot.1" 2>&1
        echo "-- mount units shipped by the image"
        ls "$R/usr/lib/systemd/system" 2>&1 | grep '\.mount$'
        echo "-- mount units and overrides in /etc"
        ls -la "$R/etc/systemd/system" 2>&1 | grep '\.mount'
        echo "-- fstab"
        cat "$R/etc/fstab" 2>&1
        echo "-- units the composed root enables"
        ls "$R/usr/lib/systemd/system/basic.target.wants" 2>&1 | head -20
        ls "$R/etc/systemd/system/basic.target.wants" 2>&1 | head -20
        ls "$R/etc/systemd/system/multi-user.target.wants" 2>&1 | head -40
        echo "-- armada ostree helpers as the composed root sees them"
        ls -la "$R/usr/lib/armada" 2>&1
        ls -la "$R/etc/systemd/system/armada-ostree-confirm.service" 2>&1
        ls -la "$R/usr/lib/systemd/system/armada-ostree-confirm.service" 2>&1
        echo "-- bootloader specs"
        for f in /boot/loader."$bootversion"/entries/ostree-*.conf; do
            echo "[$f]"
            cat "$f" 2>&1
        done
    } >"$out" 2>&1
    for m in dev proc sys; do
        umount -l "$R/$m" 2>/dev/null
    done
}

if [ "$dryrun" = probe ]; then
    probe_report "$state/dryrun.log"
    # One-shot flag, and the kill switch goes off: a probe is a measurement, not
    # an armed attempt, so the board has to come back flat by itself.
    printf 'no\n' > /etc/armada/ostree-boot 2>/dev/null
    rm -f "$state/dryrun" "$state/attempt" 2>/dev/null
    log "PROBE wrote $state/dryrun.log ($(wc -c < "$state/dryrun.log" 2>/dev/null) bytes), marker set to no - continuing on the flat root"
    flush
    fallback "probe finished - see $state/dryrun.log"
fi

# ---- move the kernel's filesystems and pivot ------------------------------
# The boot initramfs hands over /dev, /proc and /sys, but after switch_root they
# are not necessarily movable: the kernel refuses MS_MOVE for some of the mounts
# it created during the initramfs stage (EINVAL on this board). Mounting the same
# pseudo filesystem fresh gives PID 1 the identical content, so a failed move is
# not a reason to give up on the composed root - the mountinfo line before each
# attempt is what tells the two cases apart in the log.
mi=
while read -r mnt_id parent_id mnt_dev mnt_root mnt_point mnt_opts rest; do
    case "$mnt_point" in
        /dev|/proc|/sys) mi="$mi [$mnt_point dev=$mnt_dev root=$mnt_root opts=$mnt_opts]" ;;
    esac
done < /proc/self/mountinfo
log "kernel mounts:$mi"
for m in dev proc sys; do
    case $m in
        dev)  fstype=devtmpfs; src=devtmpfs ;;
        proc) fstype=proc;     src=proc ;;
        sys)  fstype=sysfs;    src=sysfs ;;
    esac
    mount --make-rprivate "/$m" 2>/dev/null
    if ! mount --move "/$m" "$new/$m" 2>>"$logf"; then
        mount -t "$fstype" "$src" "$new/$m" 2>>"$logf" \
            || fallback "cannot move /$m and cannot mount $fstype on $new/$m"
        log "note: /$m was mounted fresh as $fstype after MS_MOVE failed"
    fi
done
mkdir -p "$new/sysroot/.stage1-oldroot" 2>/dev/null || fallback "cannot create put_old"
if pivot_root "$new" "$new/sysroot/.stage1-oldroot" 2>/dev/null; then
    cd / || fallback "cannot cd / after pivot_root"
    # A move that failed left its kernel filesystem mounted under the old root.
    for m in dev proc sys; do umount -l "/sysroot/.stage1-oldroot/$m" 2>/dev/null; done
    umount -l /sysroot/.stage1-oldroot 2>/dev/null
    rmdir /sysroot/.stage1-oldroot 2>/dev/null
    logf=/sysroot/armada-ostree/boot.log
    log "COMPOSED root=$(stat -c '%d:%i' /) init=$init"
    # Field 5 of mountinfo is the mount point; field 2 is the parent id, which is
    # what this line used to print, so the log never showed what was really mounted
    # where. major:minor plus the fstype is what tells a bind from a tmpfs.
    log "composed mounts: $(awk '{print $4" "$5" "$6}' /proc/self/mountinfo | tr '\n' ';')"
    log "composed /etc=$(stat -c 'dev=%d ino=%i' /etc 2>/dev/null) /var=$(stat -c 'dev=%d ino=%i' /var 2>/dev/null) machine=$(cat /etc/machine-id 2>/dev/null)"
    # A forced power cut is the only way out of a board that never answers, and a
    # page-cache-only boot.log loses exactly the lines that explain the dead boot.
    # Every milestone before systemd takes over has to reach the platter.
    flush
else
    # The flat root is gone as /, but its content is still reachable through
    # $new, so a chroot keeps the same composed tree as the last resort.
    log "pivot_root failed, using chroot"
    if [ "$dryrun" = pivot ]; then
        # No pivot means no composed view: report what is on disk under $new and
        # come straight back, still refusing to start systemd.
        printf 'no\n' > "$new/etc/armada/ostree-boot" 2>/dev/null
        rm -f "$new/armada-ostree/dryrun" 2>/dev/null
        {
            echo "armada-ostree dry run: pivot_root failed, no composed view"
            echo "root=$(stat -c '%d:%i' /)"
            cat /proc/self/mountinfo
            ls -la "$new/run" 2>&1
        } >"$new/armada-ostree/dryrun.log" 2>&1
        log "DRY RUN stopped at the chroot fallback - marker set to no, rebooting"
        hard_reboot
        log "reboot did not take - force-reboot the board to read $state/dryrun.log"
        exec /bin/sh
    fi
    if [ -n "${ARMADA_OSTREE_STAGE1_EXEC:-}" ]; then
        exec chroot "$new" /bin/sh -c "$ARMADA_OSTREE_STAGE1_EXEC"
    fi
    exec chroot "$new" "$init" "$@"
fi
if [ "$dryrun" = pivot ]; then
    dryrun_report /sysroot/armada-ostree/dryrun.log
    # Leave the board where it can be reached: the flag is one-shot, and the kill
    # switch goes off so the boot after this dry run is a flat one.
    printf 'no\n' > /sysroot/etc/armada/ostree-boot 2>/dev/null
    rm -f /sysroot/armada-ostree/dryrun /sysroot/armada-ostree/dryrun-pivot /sysroot/armada-ostree/attempt 2>/dev/null
    log "DRY RUN wrote /sysroot/armada-ostree/dryrun.log ($(wc -c < /sysroot/armada-ostree/dryrun.log 2>/dev/null) bytes) - marker set to no, rebooting"
    flush
    log "post-dry-run marker = [$(tr -d ' \t\r\n' < /sysroot/etc/armada/ostree-boot 2>/dev/null)]"
    hard_reboot
    log "reboot did not take - force-reboot the board to read /armada-ostree/dryrun.log"
    exec /bin/sh
fi
# The loop test runs this as a real root switch and then inspects the composed
# root from inside the same process, so it can replace the final exec.
if [ -n "${ARMADA_OSTREE_STAGE1_EXEC:-}" ]; then
    exec /bin/sh -c "$ARMADA_OSTREE_STAGE1_EXEC"
fi
exec "$init" "$@"
