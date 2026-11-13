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
# A113 = A112, order and volume fixed.  The stage log on the card says it
# plainly: A108 printed PATCH_DONE rc=0 and then SWITCH_ROOT_TO, while A109,
# A110, A111 and A112 printed PATCH_RUN and nothing ever after - no PATCH_DONE,
# no SWITCH_ROOT_TO.  Those boots never entered the installed root, so everything
# in the second half of this script (the sddm wants link, the autologin, the
# start limit, the diag unit) never ran.  That is the real reason there is still
# no desktop, and it also means "no y700-aNNN.txt on the card" was never evidence
# about systemd - it was evidence about this script.
#
# What A109 introduced was heavy SD traffic in the initramfs: the journal, 285 MB
# in A109 and 16 MB in A110-A112.  Sustained mmc writes are exactly what this
# board dies on (see the aggre2 note at the top of /init).  So:
#   * ARM FIRST.  Sections 2-5 are a few KB of UFS writes; they must not wait
#     behind an evidence pass that can end the boot.
#   * the journal is not copied at all.  The in-root diagnostic prints the
#     journal as TEXT: readable, small, and parseable without a card reader that
#     speaks the journal format.
#   * the previous boot's console comes from /tmp/pst - /init already read
#     /sys/fs/pstore/console-ramoops-0 into RAM, and pstore reads are one-shot,
#     so mounting pstore here would only ever see an empty directory.
#   * evidence is written in descending value, syncing after each item, so a
#     death leaves a trail instead of silence.
#
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
# A114 = A113 plus the answer to the one question A113 could not ask.
#
# A113 got us into the installed root (weston appeared, touch worked), and its
# evidence is unambiguous about what is missing: sddm is never even attempted.
#   * is-active says inactive for sddm, display-manager and graphical.target at
#     up=12 AND at up=152, while multi-user.target is reached;
#   * the failed-unit list is empty and `journalctl -b -u sddm' has no records
#     at all, so there is no start, no crash and no error to read;
#   * every journal window copied off the card is nothing but Y700-HB, one
#     KERN_EMERG heartbeat per second - 600 lines covered 13 s to 148 s of the
#     boot, so systemd's own words were pushed out of every window;
#   * `journalctl -b -p 3' held nothing but those heartbeats, i.e. no job
#     failed.  A pending job, not a failed one, is what leaves a target inactive.
# Two facts read straight out of the pristine image explain the shape of it:
#   * graphical.target (what default.target points at) carries
#     After=multi-user.target rescue.service rescue.target display-manager.service
#     - its job cannot complete until the display manager job completes.  A
#     display-manager job that is queued-but-waiting therefore parks
#     graphical.target inactive while multi-user.target activates, which is
#     exactly the observed state, and systemd-analyze said
#     "Bootup is not yet finished".
#   * the image does not want sddm.service, it wants display-manager.service,
#     which the image ships as a symlink; sddm.service itself carries
#     Alias=display-manager.service, Conflicts=getty@tty1.service and
#     PartOf=graphical.target.
# What A114 does about that:
#   * arm sddm on the target that is provably reached: an absolute
#     multi-user.target.wants/sddm.service link, next to the graphical one;
#   * make sure display-manager.service (the name graphical.target actually
#     Wants=) exists and is not masked;
#   * unmask the image's own stuck-job reporter, armada-splash-stall;
#   * ask systemd directly what it is waiting for instead of reading a journal
#     window: get-default, is-system-running, list-jobs, list-units
#     --state=activating,waiting, status of the four units that matter,
#     list-dependencies --after, critical-chain;
#   * `grep -v Y700-' in front of every journal copy so the heartbeat cannot
#     eat the window again, and a separate y700-systemd.txt (-t systemd);
#   * if sddm still is not up, start sddm.service and then graphical.target by
#     hand, each under `timeout', reporting rc and output - rc=124 plus the
#     job list names the unit everything is queued behind;
#   * only then fall back to the weston session, so the panel is never dead.
# The rootstate dump is finally named after its own round (A111-A113 all wrote
# a110-rootstate.txt, so three rounds of evidence overwrote each other).
# A115 = A114 (Plasma Mobile works on the panel) + the WLAN chain.
#
# What the desktop round proved: the default unit on this boot is
# multi-user.target (get-default printed "found systemd.unit on the kernel
# command line, which overrides the default unit"), which is why A111-A113 saw
# graphical.target inactive and sddm untouched - the wants link on
# graphical.target could never matter.  Arming sddm.service in
# multi-user.target.wants started it, and Plasma Mobile came up on the panel.
#
# What is left for Wi-Fi, and what A115 does about each link in the chain:
#   * the DTB: the QCA6490 sits on PCIe0 (pcie@1c00000, child wifi@0 with
#     compatible "pci17cb,1103").  The vendor DT has both the host and its
#     phy@1c06000 "okay"; our minimal sweep pinned them off in MINIMAL_NODES.
#     A115 unpins exactly those two nodes (the regenerated DT differs from
#     A104-A114 by two status lines).
#   * the power sequence: QCA6490/WCN6855 needs wlan-en/bt-en/xo-clk and its
#     PMU rails brought up before the link trains.  In this kernel that is
#     drivers/power/sequencing/pwrseq-qcom-wcn.c (matches the wcn6855-pmu node
#     the board DT already carries) behind drivers/pci/pwrctrl/
#     pci-pwrctrl-pwrseq.c (matches "pci17cb,1103") which pcie-qcom powers on
#     inside host_init, before link training.  POWER_SEQUENCING and
#     POWER_SEQUENCING_QCOM_WCN were not enabled; this round enables them.
#   * the firmware: the root ships every linux-firmware blob as .xz, and the
#     mainline firmware loader has no decompressor, so ath11k would look for
#     ath11k/WCN6855/hw2.1/amss.bin and find nothing.  A115 unpacks the ath11k
#     blobs in place (busybox unxz, keeping the .xz originals) - once, guarded
#     by a marker.  The board file is already right: the distro board-2.bin
#     holds bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,
#     subsystem-device=0108,qmi-chip-id=18,qmi-board-id=255, i.e. the same key
#     the SM8475/QCA6490 reference port uses, so no custom board file is needed
#     unless the enumeration says our subsystem id differs.
#   * the evidence: the diagnostic now reports PCI devices with vendor/device/
#     subsys/driver, the pwrctrl/pwrseq platform devices, net interfaces,
#     rfkill, the ath11k firmware directory, and every kernel line mentioning
#     pci/ath11k/wcn/pwrseq - plus pci= and net= in the repeated panel summary,
#     so the state is readable with no card in the slot.
# A116 = the desktop that A114 delivered, plus an answer to the one display
# problem that is left: press power to blank the panel, press again to wake it,
# and the touchscreen is dead until reboot.
#
# What the source says, before any guessing:
#   * drivers/input/touchscreen/novatek-nt36523n-spi.c has NO PM ops at all -
#     no suspend, no resume, no notifier.  Everything runs from the drm_panel
#     follower: panel_prepared() does the whole bring-up (engine reset, release
#     the reset GPIO, read the trim ID, download the 196 KiB firmware, register
#     the input device once behind input_registered, select the event page,
#     enable_irq) and prints "finger input ready"; panel_unpreparing() disables
#     the IRQ, releases contacts and re-asserts reset.
#   * drivers/gpu/drm/drm_panel.c has the ordering right: panel prepare() first,
#     then the followers; followers first, then panel unprepare.  So a real
#     dpms cycle SHOULD bring the touch IC back on its own.
#   * drm_panel_add_follower() calls panel_prepared() immediately when the panel
#     is already prepared - which is exactly why an unbind/bind from userspace
#     is a complete cold bring-up, and is the remedy this round installs.
#   * drivers/gpu/drm/panel/panel-novatek-nt36523.c (the real panel for
#     compatible "lenovo,y700-nt36523n", it replaced the A102 stub) enables vddio
#     and toggles reset in prepare/unprepare and registers a backlight device,
#     so /sys/class/backlight is a legitimate place to watch dpms.
#
# Four failure modes, separated by counters rather than by watching the screen:
#   1 the panel is never re-prepared          -> no nvt lines at all after a wake
#   2 the re-init runs and fails             -> an nvt error line (trim ID/fw)
#   3 the re-init succeeds but the IC is deaf -> "finger input ready" grows while
#                                               the touch IRQ stays flat
#   4 the kernel is fine and kwin is not     -> the touch IRQ moves under a
#                                               finger yet nothing moves on screen
# y700-touchd.sh samples once a second: the touch IRQ count (the driver requests
# it under dev_name(), i.e. spi0.0, so /proc/interrupts carries it), the
# backlight brightness/bl_power, a ready/error count of the driver's own kernel
# lines, key events read straight out of the evdev nodes (the power and volume
# keys are free to watch in parallel - evdev copies every event to every open
# client), and who holds /dev/input nodes.  Six seconds after a 0 -> non-zero
# backlight transition, and on a volume-key press, it rebinds the SPI driver.
# /usr/local/bin/y700-touch-revive does that once, so it also works from a
# terminal, or from the buttons: touch dies, press volume, six seconds later it
# is back.
#
# The kernel and the DTB are the A104/A114 bytes, unchanged: nothing that could
# break the boot is touched this round.  A115's PCIe unpin stays built and
# parked at /tmp/y700/a1/a1.dtb.a115 for the Wi-Fi round that follows.

# A118 = the round that fixes the touch-after-blank failure, because A117 put the
# real cause on the card.  The IC was never "deaf for an unknown reason":
#   [   34.548208] novatek-nt36523n-spi spi0.0: NVT-STAGE 1 reset line released, engine reset written
#   [   34.556096] novatek-nt36523n-spi spi0.0: Direct firmware load for novatek/lenovo-tb320fc.bin failed with error -2
#   [   34.556946] novatek-nt36523n-spi spi0.0: error -ENOENT: failed to load novatek/lenovo-tb320fc.bin
#   [   34.557765] panel-novatek-nt36523 ae94000.dsi.0: nvt_nt36523n_panel_prepared failed: -2
# The panel driver unprepares/prepares itself on a dpms blank+wake, so the driver
# re-runs its whole bring-up without being asked - and every one of those
# re-bring-ups dies in request_firmware() with -ENOENT.  The reason is that this
# boot loads the firmware from the EMBEDDED initramfs (lib/firmware/novatek/
# lenovo-tb320fc.bin is in the cpio, and the spi driver probes before
# switch_root), while the installed root has no novatek directory under
# /usr/lib/firmware at all.  So: touch works until the first blank, the panel
# then holds the IC in reset, and no re-init can ever succeed because the
# firmware is not findable any more.  A116/A117 chased power sequencing; the
# board said "file not found" the whole time.
#
# A118 therefore does one real thing: copy the firmware from the initramfs into
# the installed root (section 4d), so both the panel's own re-prepare and the
# watchdog revive can complete.  The A117 watchdog stays as the belt: with the
# firmware present the driver should re-register by itself and the ladder prints
# "LADDER step N skipped: the driver already re-registered".
# Kernel and DTB stay the A104/A114 bytes, exactly as in A117.

DEV=$1
R=$2
CARD=$3
K="Y700-A124"
P() { echo "<3>$K $*"; }
LOG="$R/var/log/y700-a124.txt"
DONE="$R/var/lib/y700/a124.done"
U() { echo "$*" >> "$LOG" 2>/dev/null; }

[ -n "$R" ] || { P "REFUSE no root mountpoint"; exit 1; }
[ -d "$R/usr/lib/systemd/system" ] || { P "REFUSE $R is not the Armada root"; exit 1; }
mkdir -p "$R/var/log" "$R/var/lib/y700" "$R/etc/systemd/system" 2>/dev/null
P "patch start dev=$DEV card=[$CARD] up=$(cut -d . -f 1 /proc/uptime)"

# ---- 0. the kernel ring buffer, on the card, before anything can die ----
if [ -n "$CARD" ] ; then
	mkdir -p /mnt/kmsg 2>/dev/null
	if mount -o rw,sync "$CARD" /mnt/kmsg 2>/dev/null ; then
		mkdir -p /mnt/kmsg/y700-out 2>/dev/null
		busybox dmesg > /mnt/kmsg/y700-out/a124-kmsg-early.tmp 2>&1
		mv -f /mnt/kmsg/y700-out/a124-kmsg-early.tmp /mnt/kmsg/y700-out/a124-kmsg-early.txt 2>/dev/null
		busybox sync
		busybox sync
		P "KMSG early saved lines=$(wc -l < /mnt/kmsg/y700-out/a124-kmsg-early.txt 2>/dev/null) ath11k=$(busybox dmesg 2>/dev/null | grep -aci ath11k)"
		umount /mnt/kmsg 2>/dev/null
	else
		P "KMSG early mount failed card=$CARD"
	fi
else
	P "KMSG early skipped: no card"
fi

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
# graphical.target is the default, but its own job cannot finish on this board:
# the unit orders itself After=display-manager.service, so a display-manager
# job that is queued and waiting keeps the target inactive - the state A113
# measured at up=12 and up=152 while multi-user.target was reached.  Arm the
# display manager on the target that provably IS reached, too.
ln -sf /usr/lib/systemd/system/sddm.service "$R/etc/systemd/system/multi-user.target.wants/sddm.service"
# The name graphical.target actually Wants= is display-manager.service, an alias
# the image provides as a symlink.  If that alias is missing or masked, no wants
# link on sddm.service itself can ever pull the display manager in.
DML="$R/etc/systemd/system/display-manager.service"
if [ -L "$DML" ] && [ "$(readlink "$DML")" = "/dev/null" ] ; then
    rm -f "$DML"
    U "display-manager.service was masked, unmasked"
fi
[ -L "$DML" ] || ln -sf /usr/lib/systemd/system/sddm.service "$DML"
U "display-manager.service=$(readlink "$DML" 2>/dev/null) multi-user_wants=$(readlink "$R/etc/systemd/system/multi-user.target.wants/sddm.service" 2>/dev/null)"
for l in "$R/etc/systemd/system/multi-user.target.wants/sddm.service" "$DML" ; do
    [ -e "$R$(readlink "$l")" ] || P "WANTS_LINK_BROKEN ${l##*/} -> $(readlink "$l")"
done
# The image ships its own reporter for exactly this symptom - a systemd job that
# never finishes, sitting behind the splash.  A111-A113 masked it wholesale;
# unmasked, the panel itself names the stuck unit.
if [ -L "$R/etc/systemd/system/armada-splash-stall.service" ] && [ "$(readlink "$R/etc/systemd/system/armada-splash-stall.service")" = "/dev/null" ] ; then
    rm -f "$R/etc/systemd/system/armada-splash-stall.service"
    U "armada-splash-stall unmasked (it reports the stuck job)"
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

# ---- 4b. ath11k firmware: .xz on disk, and the kernel cannot decompress ----
FW="$R/usr/lib/firmware/ath11k"
if [ -d "$FW" ] && [ ! -f "$R/var/lib/y700/ath11k-fw.done" ] ; then
    N=0
    M=0
    for x in "$FW"/*.xz "$FW"/*/*.xz "$FW"/*/*/*.xz ; do
        [ -f "$x" ] || continue
        b="${x%.xz}"
        if [ -e "$b" ] ; then M=$((M + 1)); continue; fi
        if busybox unxz -c "$x" > "$b" 2>/dev/null ; then N=$((N + 1)); else rm -f "$b"; fi
    done
    echo "ath11k firmware unpacked=$N kept=$M up=$(cut -d . -f 1 /proc/uptime)" > "$R/var/lib/y700/ath11k-fw.done"
    P "ATH11K-FW unpacked=$N kept=$M hw21=[$(ls "$FW"/WCN6855/hw2.1/ 2>/dev/null | busybox tr '\n' ' ')]"
    U "ath11k firmware unpacked=$N kept=$M"
else
    P "ATH11K-FW dir=[$(ls -d "$FW" 2>/dev/null)] marker=[$(cat "$R/var/lib/y700/ath11k-fw.done" 2>/dev/null)]"
fi

# ---- 4c. the touch watchdog: sample, and cold-restart the IC after a wake ----
# The units are armed from the initramfs because the UFS root is the only place
# they can live; the daemon runs in the installed system, not here.
mkdir -p "$R/usr/local/bin" 2>/dev/null
cat > "$R/usr/local/bin/y700-touch-revive" <<'REVIVE'
#!/bin/sh
# A116: one cold re-init of the NT36523N.  Unbind + bind the SPI driver:
# drm_panel_add_follower() calls panel_prepared() right away when the panel is
# already prepared, so a bind is a full bring-up - engine reset, reset GPIO,
# trim ID, 196 KiB firmware download, input device, event page, enable_irq.
# Safe to run by hand from the Plasma terminal: y700-touch-revive myhand
DRV=novatek-nt36523n-spi
DDIR=/sys/bus/spi/drivers/$DRV
LOG=/var/log/y700-touchd.txt
reason=${1:-manual}

upt() { cut -d . -f 1 /proc/uptime; }
SAY() { echo "<3>Y700-A124-REVIVE $*" > /dev/kmsg 2>/dev/null; echo "$(upt) REVIVE $*" >> "$LOG" 2>/dev/null; }
spiname() {
	for d in "$DDIR"/spi*; do
		[ -e "$d" ] || continue
		echo "${d##*/}"
		return 0
	done
}
tpirq() {
	n=$(spiname)
	[ -n "$n" ] || { echo na; return; }
	v=$(awk -v want="$n" 'index($0, want) {
			t = 0
			for (i = 2; i <= NF; i++) { if ($i ~ /^[0-9]+$/) t += $i; else break }
			print t
		}' /proc/interrupts 2>/dev/null)
	[ -n "$v" ] || v=0
	echo "$v"
}
kvt() {
	journalctl -b -k --no-pager 2>/dev/null | grep -aiE 'nvt|nt36523|finger input|trim id|novatek' \
		> /tmp/y700-kvt.txt 2>/dev/null
	echo "$(grep -ac 'finger input ready' /tmp/y700-kvt.txt 2>/dev/null)/$(grep -acE 'failed to|unsupported|timed out|error=[^0]|-E[IO]' /tmp/y700-kvt.txt 2>/dev/null)"
}

ns=""
for d in "$DDIR"/spi*; do
	[ -e "$d" ] && ns="$ns ${d##*/}"
done
if [ -z "$ns" ] ; then
	SAY "$reason NO-BOUND-DEVICE drv=$DRV others=[$(ls /sys/bus/spi/drivers 2>/dev/null | tr '\n' ',')]"
	exit 1
fi
q0=$(tpirq)
k0=$(kvt)
SAY "$reason start dev=[$ns] irq=$q0 kvt=$k0"
for n in $ns; do
	echo "$n" > "$DDIR/unbind" 2>>"$LOG"
done
sleep 1
for n in $ns; do
	echo "$n" > "$DDIR/bind" 2>>"$LOG"
done
sleep 4
SAY "$reason end dev=[$(ls "$DDIR" 2>/dev/null | tr '\n' ',')] irq=$(tpirq) was=$q0 kvt=$(kvt) was=$k0 ev=[$(ls /sys/class/input 2>/dev/null | tr '\n' ',')]"
echo "-- last nvt lines --" >> "$LOG" 2>/dev/null
tail -n 14 /tmp/y700-kvt.txt >> "$LOG" 2>/dev/null
SAY "$reason done"
REVIVE
chmod 0755 "$R/usr/local/bin/y700-touch-revive"
U "y700-touch-revive installed mode=$(stat -c %a "$R/usr/local/bin/y700-touch-revive" 2>/dev/null)"
cat > "$R/usr/local/bin/y700-touchd.sh" <<'TOUCHD'
#!/bin/sh
# A118: the touch watchdog, second attempt.  A116 measured the board and came
# back with three facts:
#   * dpms is NOT in brightness.  ktz8866-backlight keeps brightness=1027 all the
#     time and switches bl_power 0 -> 4 (FB_BLANK_POWERDOWN) -> 0.  A116 keyed on
#     brightness, saw no transition, and therefore never revived.
#   * the touch IRQ is alive while the desktop works (+352 +19 +45 +31 +85 +115
#     +75 inside ten seconds of finger time) and froze at 1214 from the blank
#     onwards: after the wake the IC is deaf.
#   * "finger input ready" stayed at 1 across the wake while the driver's error
#     lines went 1 -> 4: panel_prepared() DID run again and did not reach
#     input registration - the cold bring-up itself failed.
# So: trigger on bl_power, watch the power key as well (pmic_pwrkey is event0;
# logind holds it, but evdev copies every event to every open reader), stream the
# kernel's own nvt/panel lines into this log so the failure text lands on the
# card, and re-init on a ladder (5 s / 20 s / 45 s after the wake) stopping as
# soon as a bring-up actually succeeds.
CONF=/etc/y700-touchd.conf
LOG=/var/log/y700-touchd.txt
HITS=/run/y700-keyhits
KV=/run/y700-kvt.txt
K=Y700-A124-TOUCHD
DRV=novatek-nt36523n-spi
DDIR=/sys/bus/spi/drivers/$DRV
REV=/usr/local/bin/y700-touch-revive
revive=auto
ladder="5 20 45"
sample=1
cardpush=60
keyrevive="114 115"
gate=30
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

upt() { cut -d . -f 1 /proc/uptime; }
P() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; }
L() { echo "$(upt) $*" >> "$LOG" 2>/dev/null; }

# ---- the panel's dpms state, as the board actually shows it ----
bpath() {
	for b in /sys/class/backlight/*; do
		[ -e "$b/bl_power" ] && { echo "$b"; return; }
	done
	for b in /sys/class/backlight/*; do
		[ -e "$b/brightness" ] && { echo "$b"; return; }
	done
}
bpow() {
	b=$(bpath)
	[ -n "$b" ] || { echo NA; return; }
	v=$(cat "$b/bl_power" 2>/dev/null)
	[ -n "$v" ] || v=NA
	echo "$v"
}
sens() {
	b=$(bpath)
	[ -n "$b" ] || { echo none; return; }
	echo "${b##*/}=$(cat "$b/brightness" 2>/dev/null)/$(cat "$b/bl_power" 2>/dev/null)"
}

# ---- the touch driver, as seen from its bus device ----
spiname() {
	for d in "$DDIR"/spi*; do
		[ -e "$d" ] || continue
		echo "${d##*/}"
		return 0
	done
}
tpirq() {
	n=$(spiname)
	[ -n "$n" ] || { echo na; return; }
	v=$(awk -v want="$n" 'index($0, want) {
			t = 0
			for (i = 2; i <= NF; i++) { if ($i ~ /^[0-9]+$/) t += $i; else break }
			print t
		}' /proc/interrupts 2>/dev/null)
	[ -n "$v" ] || v=0
	echo "$v"
}
klines() {
	journalctl -b -k --no-pager 2>&1 | grep -av 'Y700-' \
		| grep -aiE 'nvt|nt36523|novatek|finger input|trim id' > "$KV" 2>/dev/null
}
kvt() {
	klines
	echo "$(grep -ac 'finger input ready' "$KV" 2>/dev/null)/$(grep -acE 'failed to|unsupported|timed out|error=[^0]|-E[IO]' "$KV" 2>/dev/null)"
}
evnodes() { ls /sys/class/input 2>/dev/null | grep -c '^event'; }
grabbers() {
	for p in /proc/[0-9]*; do
		for f in "$p"/fd/*; do
			t=$(readlink "$f" 2>/dev/null) || continue
			case "$t" in /dev/input/*) echo "$(cat "$p"/comm 2>/dev/null)${t}";; esac
		done
	done 2>/dev/null | sort -u | tr '\n' ','
}

pushtocard() {
	mkdir -p /mnt/tcard 2>/dev/null
	C=""
	for d in /dev/mmcblk*p[0-9]; do
		mount -t vfat -o rw,sync "$d" /mnt/tcard 2>/dev/null || continue
		if [ -d /mnt/tcard/y700-out ] ; then C=$d; break; fi
		umount /mnt/tcard 2>/dev/null
	done
	[ -n "$C" ] || { P "CARD none blocks=[$(ls /sys/block 2>/dev/null | tr '\n' ',')]"; return; }
	mkdir -p /mnt/tcard/y700-out 2>/dev/null
	tail -n 300 "$LOG" > /mnt/tcard/y700-out/y700-touchd.tmp 2>/dev/null && mv -f /mnt/tcard/y700-out/y700-touchd.tmp /mnt/tcard/y700-out/y700-touchd.txt 2>/dev/null
	B=$(wc -c < /mnt/tcard/y700-out/y700-touchd.txt 2>/dev/null)
	sync
	sync
	umount /mnt/tcard 2>/dev/null
	P "CARD ok dev=$C bytes=$B"
}

# ---- key events: one open fd per node so nothing is missed (input_event is 24
# bytes on arm64: 16 timeval + type/code u16 + value s32) ----
keywatch() {
	cat "/dev/input/$1" 2>/dev/null | od -An -v -tu1 -w24 2>/dev/null | awk '
		{
			if (NF < 24) next
			type = $17 + $18 * 256
			code = $19 + $20 * 256
			val = $21 + $22 * 256 + $23 * 65536 + $24 * 16777216
			if (val >= 2147483648) val = val - 4294967296
			if (type == 1) { print code, val; fflush() }
		}' | while read -r code val; do
			echo "$(upt) KEY node=$1 code=$code value=$val irq=$(tpirq)" >> "$HITS" 2>/dev/null
			echo "$(upt) KEY node=$1 code=$code value=$val" >> "$LOG" 2>/dev/null
		done
}

# ---- the kernel's own words, in order, as they happen ----
kmsgwatch() {
	journalctl -f -k -o short-monotonic --no-pager 2>/dev/null \
		| grep --line-buffered -aiE 'nvt|nt36523|novatek|finger input|trim id|panel@0|dpms|suspend|resume|freez|backlight' \
		| grep --line-buffered -av 'Y700-' >> "$LOG" 2>/dev/null
}

revive_now() {
	why=$1
	lastrev=$(upt)
	k0=$(kvt)
	q0=$(tpirq)
	L "ATTEMPT $why before kvt=$k0 irq=$q0 pw=$(bpow)"
	"$REV" "$why"
	sleep 2
	k1=$(kvt)
	q1=$(tpirq)
	case "$k1" in
		*/*) : ;;
	esac
	L "ATTEMPT $why after  kvt=$k1 irq=$q1 bound=[$(spiname)] ev=$(evnodes) pw=$(bpow)"
	KTAIL=$(tail -n 8 "$KV" 2>/dev/null | tr '\n' '|')
	L "ATTEMPT $why nvt-tail $KTAIL"
}

[ -e /run/y700-no-touchd ] && { P "exit: /run/y700-no-touchd exists"; exit 0; }
: > "$HITS" 2>/dev/null

devs=""
names=""
for e in /sys/class/input/event*; do
	nm=$(cat "$e/device/name" 2>/dev/null)
	low=$(echo "$nm" | tr 'A-Z' 'a-z' 2>/dev/null)
	case "$low" in
		*keys*|*key*|*pon*|*pwr*|*resin*|*power*) devs="$devs ${e##*/}"; names="$names ${e##*/}:$nm";;
	esac
done

L "=== $K start up=$(upt) drv=$DRV bound=[$(spiname)] conf=[revive=$revive ladder=[$ladder] sample=$sample cardpush=$cardpush keyrevive=[$keyrevive] gate=$gate]"
L "sensors bl=[$(sens)] keys=[$names] input=[$(ls /sys/class/input 2>/dev/null | tr '\n' ',')] irq=$(tpirq) kvt=$(kvt)"
P "start bound=$(spiname) bl=[$(sens)] keys=[$names]"
for nd in $devs; do keywatch "$nd" & done
kmsgwatch &

lastpw=NA
previrq=-1
prevkvt=--
hits=0
blankseen=0
lastrev=0
unblankat=0
ladidx=0
n=0
while : ; do
	n=$((n + 1))
	pw=$(bpow)
	irq=$(tpirq)
	if [ "$irq" != na ] && [ "$previrq" -ge 0 ] && [ "$irq" != "$previrq" ] ; then
		L "IRQMOVE +$((irq - previrq)) total=$irq pw=$pw"
	fi
	[ "$irq" != na ] && previrq=$irq
	if [ "$pw" != "$lastpw" ] ; then
		L "PWSTATE $lastpw -> $pw irq=$irq kvt=$(kvt) grab=[$(grabbers)]"
		if [ "$pw" = 4 ] ; then
			blankseen=$((blankseen + 1))
			unblankat=0
			ladidx=0
			L "BLANKED n=$blankseen bl_power=4 (FB_BLANK_POWERDOWN)"
		elif [ "$lastpw" = 4 ] ; then
			unblankat=$(upt)
			ladidx=0
			L "UNBLANK after=$unblankat blankseen=$blankseen revive=$revive ladder=[$ladder]"
			klines
			L "UNBLANK nvt-tail $(tail -n 14 "$KV" 2>/dev/null | tr '\n' '|')"
		fi
		lastpw=$pw
	fi
	# the ladder: re-init 5 s, 20 s and 45 s after the wake, and stop as soon as
	# a bring-up has actually printed "finger input ready"
	if [ "$unblankat" -gt 0 ] && [ "$revive" = auto ] ; then
		i=0
		want=-1
		for off in $ladder ; do
			i=$((i + 1))
			if [ "$i" -gt "$ladidx" ] ; then want=$off; break; fi
		done
		if [ "$want" -ge 0 ] && [ "$(upt)" -ge $((unblankat + want)) ] ; then
			k0=$(kvt)
			ladidx=$i
			if [ "${k0%%/*}" -gt 1 ] ; then
				L "LADDER step $i skipped: the driver already re-registered (kvt=$k0)"
			else
				revive_now "ladder$i"
			fi
		fi
	fi
	if [ $((n % 5)) -eq 0 ] ; then
		k=$(kvt)
		[ "$k" != "$prevkvt" ] && { L "KVT $prevkvt -> $k (ready/errors this boot)"; prevkvt=$k; }
	fi
	h=$(wc -l < "$HITS" 2>/dev/null)
	[ -n "$h" ] || h=0
	if [ "$h" != "$hits" ] ; then
		line=$(tail -n 1 "$HITS" 2>/dev/null)
		code=$(echo "$line" | sed -n 's/.*code=\([-0-9]*\).*/\1/p')
		val=$(echo "$line" | sed -n 's/.*value=\([-0-9]*\).*/\1/p')
		for kk in $keyrevive ; do
			if [ "$code" = "$kk" ] && [ "$val" = 1 ] ; then
				L "KEYREVIVE code=$code gate=$((upt - lastrev))"
				if [ "$revive" = auto ] && [ $((upt - lastrev)) -ge $gate ] ; then
					revive_now keypress
				fi
			fi
		done
		hits=$h
	fi
	if [ -e /run/y700-revive ] ; then
		rm -f /run/y700-revive 2>/dev/null
		revive_now flag
	fi
	if [ $((n % 20)) -eq 0 ] ; then
		L "HB irq=$irq pw=$pw sens=[$(sens)] kvt=$(kvt) ev=$(evnodes) hits=$hits blank=$blankseen lad=$ladidx bound=[$(spiname)]"
	fi
	if [ $((n % cardpush)) -eq 0 ] ; then
		pushtocard
	fi
	sleep "$sample"
done
TOUCHD
chmod 0755 "$R/usr/local/bin/y700-touchd.sh"
U "y700-touchd.sh installed mode=$(stat -c %a "$R/usr/local/bin/y700-touchd.sh" 2>/dev/null)"
cat > "$R/etc/y700-touchd.conf" <<'TCONF'
# read by /usr/local/bin/y700-touchd.sh at every start
# revive=auto rebinds the SPI touch driver; revive=off makes it a pure observer
revive=auto
# seconds after the panel comes back (bl_power 4 -> 0) for each re-init attempt
ladder="5 20 45"
# seconds per sample
sample=1
# seconds between mirrors of the log tail onto the SD card
cardpush=60
# linux input event codes that ask for a revive by hand (KEY_VOLUMEDOWN,
# KEY_VOLUMEUP).  KEY_POWER (116) is deliberately not here: waking the panel
# already queues the ladder, and a power press must not also re-probe the IC.
keyrevive="114 115"
# minimum seconds between two revives that were not part of the ladder
gate=30
TCONF
cat > "$R/etc/systemd/system/y700-touchd.service" <<'TU'
[Unit]
Description=Y700 A124 touch watchdog (panel blank, NT36523N re-init)
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/y700-touchd.sh
Restart=always
RestartSec=3
Nice=10

[Install]
WantedBy=multi-user.target
TU
ln -sf ../y700-touchd.service "$R/etc/systemd/system/multi-user.target.wants/y700-touchd.service"
U "y700-touchd.service armed unit=$R/etc/systemd/system/y700-touchd.service"

# ---- 4d. put the touch firmware where the INSTALLED root can find it ----
# request_firmware() resolves against whatever is current root when the driver
# asks, not against the initramfs.  The boot-time bring-up happens before
# switch_root, so it finds the cpio copy; the dpms wake happens ~30 s later and
# finds nothing.  Copy the exact bytes the boot used into the root, twice if the
# distro keeps /lib separate, and assert with cmp rather than trusting cp.
NVT_FW_SRC=
for c in /lib/firmware/novatek/lenovo-tb320fc.bin /usr/lib/firmware/novatek/lenovo-tb320fc.bin; do
	[ -f "$c" ] && { NVT_FW_SRC="$c"; break; }
done
if [ -z "$NVT_FW_SRC" ] ; then
	P "NVT-FW no source in the initramfs - cannot fix the wake this boot"
	U "NVT-FW source=none"
else
	FWSZ=$(wc -c < "$NVT_FW_SRC")
	U "NVT-FW source=$NVT_FW_SRC size=$FWSZ sha=$(sha256sum "$NVT_FW_SRC" 2>/dev/null | cut -c1-16)"
	NFW=0
	for d in "$R/usr/lib/firmware/novatek" "$R/lib/firmware/novatek"; do
		pd=$(dirname "$d")
		[ -d "$pd" ] || { U "NVT-FW skip $d (no $pd)"; continue; }
		mkdir -p "$d" 2>/dev/null
		if cp -f "$NVT_FW_SRC" "$d/lenovo-tb320fc.bin" 2>>"$LOG" ; then
			chmod 0644 "$d/lenovo-tb320fc.bin" 2>/dev/null
			if cmp -s "$NVT_FW_SRC" "$d/lenovo-tb320fc.bin" ; then
				NFW=$((NFW + 1))
				U "NVT-FW ok $d/lenovo-tb320fc.bin size=$(wc -c < "$d/lenovo-tb320fc.bin")"
			else
				U "NVT-FW CMP-FAIL $d/lenovo-tb320fc.bin"
			fi
		else
			U "NVT-FW COPY-FAIL $d"
		fi
	done
	echo "installed=$NFW src=$NVT_FW_SRC size=$FWSZ at=$(cut -d . -f 1 /proc/uptime)" \
		> "$R/var/lib/y700/nvt-fw.done" 2>/dev/null
	P "NVT-FW installed=$NFW size=$FWSZ src=$NVT_FW_SRC"
	# The GMU/other firmware the boot loaded from here has the same problem on a
	# resume, so mirror the whole novatek directory listing into the log: cheap,
	# and it says what is actually in the root after this round.
	U "NVT-FW root-listing [$(ls "$R/usr/lib/firmware/novatek" 2>/dev/null | tr '\n' ',')]"
fi

# ---- 4e. the wifi observer: look, log, and do not touch the bus ----
# A121 proved two things at once.  Good: with the firmware reachable, MHI gets to
# "power up success" instead of -ENOENT.  Bad: driving that from a re-probe at
# runtime reboots the tablet, because ath11k_pcic_reset() writes
# PCIE_SOC_GLOBAL_RESET (drivers/net/wireless/ath/ath11k/pci.c:197-223) - a hard
# global reset of the Wi-Fi SoC - and on this SoC the PCIe link/power domain does
# not survive a mid-boot re-init.  So the re-probe is off by default now; the real
# fix lives in the initramfs (prep copies ath11k/WCN6855/hw2.1 next to the touch
# firmware, so the very first probe, which runs before switch_root, finds it).
# This service only records what the first probe achieved, and pushes the log to
# the card in the same boot.  rebind=on in /etc/y700-wifi.conf restores the
# three escalating attempts for experiments; on a normal boot it must stay off.
mkdir -p "$R/usr/local/bin" 2>/dev/null
cat > "$R/usr/local/bin/y700-wifi.sh" <<'WIFI'
#!/bin/sh
# Observes what ath11k did on this boot.  Every branch of the A12x diagnosis is
# decided by these few lines: is the endpoint bound, did MHI power up, is there a
# wlan interface, and is anything rfkill-blocked.
K=Y700-A124-WIFI
LOG=/var/log/y700-wifi.txt
CONF=/etc/y700-wifi.conf
rebind=off
if [ -f "$CONF" ] ; then
	. "$CONF" 2>/dev/null
fi
DRV=/sys/bus/pci/drivers/ath11k_pci
L() {
	echo "<3>$K $*" > /dev/kmsg 2>/dev/null
	echo "$(cut -d . -f 1 /proc/uptime) $K $*" >> "$LOG" 2>/dev/null
}
upt() { cut -d . -f 1 /proc/uptime; }
netlist() { ls /sys/class/net 2>/dev/null | tr '\n' ','; }
wlan() {
	for n in /sys/class/net/wlan*; do
		[ -e "$n" ] && { echo "${n##*/}"; return 0; }
	done
	return 1
}
devfor() {
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x17cb ] || continue
		case "$(cat "$d/device" 2>/dev/null)" in
			0x1100|0x1101|0x1103|0x1107) echo "${d##*/}"; return 0 ;;
		esac
	done
	return 1
}
kvtail() {
	journalctl -b -k --no-pager 2>/dev/null | grep -aiE 'ath11k|mhi|wcn6855|pwrctrl|pwrseq|regdb|regulatory' | tail -n 14 | tr '\n' '|'
}
push() {
	mkdir -p /mnt/tcard 2>/dev/null
	C=""
	for d in /dev/mmcblk*p[0-9]; do
		mount -t vfat -o rw,sync "$d" /mnt/tcard 2>/dev/null || continue
		if [ -d /mnt/tcard/y700-out ] ; then C=$d; break; fi
		umount /mnt/tcard 2>/dev/null
	done
	[ -n "$C" ] || { L "push no card blocks=[$(ls /sys/block 2>/dev/null | tr '\n' ',')]"; return; }
	mkdir -p /mnt/tcard/y700-out 2>/dev/null
	tail -n 200 "$LOG" > /mnt/tcard/y700-out/y700-wifi.tmp 2>/dev/null && mv -f /mnt/tcard/y700-out/y700-wifi.tmp /mnt/tcard/y700-out/y700-wifi.txt 2>/dev/null
	sync; sync
	umount /mnt/tcard 2>/dev/null
}

DEV=$(devfor)
BOUND=no
[ -n "$DEV" ] && [ -e "$DRV/$DEV" ] && BOUND=yes
L "start up=$(upt) dev=${DEV:-none} drv=$([ -d "$DRV" ] && echo present || echo absent) bound=$BOUND rebind=$rebind net=[$(netlist)]"
L "start fw=[$(ls /usr/lib/firmware/ath11k/WCN6855/hw2.1 2>/dev/null | tr '\n' ',')]"
push
if [ -n "$DEV" ] && [ "$BOUND" = no ] && [ "$rebind" = on ] ; then
	# experiment only: ath11k_pcic_reset() is a global reset of the Wi-Fi SoC,
	# and A121 rebooted the tablet doing this - keep it behind a switch.
	n=0
	for mode in bind reset rescan ; do
		n=$((n + 1))
		[ -n "$(wlan 2>/dev/null)" ] && { L "attempt $n skipped: $(wlan) appeared"; break; }
		L "attempt $n mode=$mode bound=$([ -e "$DRV/$DEV" ] && echo yes || echo no)"
		[ -e "$DRV/$DEV" ] && timeout 25 sh -c "echo \"$DEV\" > \"$DRV/unbind\"" 2>>"$LOG"
		sleep 2
		case "$mode" in
			reset) timeout 25 sh -c "echo 1 > \"/sys/bus/pci/devices/$DEV/reset\"" 2>>"$LOG"; sleep 2 ;;
			rescan)
				timeout 25 sh -c "echo 1 > \"/sys/bus/pci/devices/$DEV/remove\"" 2>>"$LOG"
				sleep 2
				timeout 25 sh -c "echo 1 > /sys/bus/pci/rescan" 2>>"$LOG"
				sleep 3 ;;
		esac
		if [ -e "/sys/bus/pci/devices/$DEV" ] && [ ! -e "$DRV/$DEV" ] ; then
			timeout 25 sh -c "echo \"$DEV\" > \"$DRV/bind\"" 2>>"$LOG"
		fi
		sleep 8
		L "attempt $n end bound=$([ -e "$DRV/$DEV" ] && echo yes || echo no) net=[$(netlist)]"
		push
	done
fi
if wlan >/dev/null ; then
	I=$(wlan)
	L "RESULT wifi-up iface=$I mac=$(cat "/sys/class/net/$I/address" 2>/dev/null) operstate=$(cat "/sys/class/net/$I/operstate" 2>/dev/null) wireless=$([ -d "/sys/class/net/$I/wireless" ] && echo yes || echo no)"
else
	L "RESULT no-wlan bound=$BOUND net=[$(netlist)]"
fi
L "RESULT rfkill=[$(rfkill list 2>/dev/null | tr '\n' ',')]"
L "RESULT kvtail $(kvtail)"
push
exit 0
WIFI
chmod 0755 "$R/usr/local/bin/y700-wifi.sh"
U "y700-wifi.sh installed mode=$(stat -c %a "$R/usr/local/bin/y700-wifi.sh" 2>/dev/null)"
cat > "$R/etc/y700-wifi.conf" <<'WCONF'
# read by /usr/local/bin/y700-wifi.sh
# rebind=on re-probes the ath11k endpoint.  It is OFF because that path writes
# PCIE_SOC_GLOBAL_RESET (a hard reset of the Wi-Fi SoC) and rebooted the tablet
# in A121.  Only turn it on while watching the serial-equivalent console.
rebind=off
WCONF
U "y700-wifi.conf written"
cat > "$R/etc/systemd/system/y700-wifi.service" <<'WU'
[Unit]
Description=Y700 A124 ath11k observer (no bus writes)
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/y700-wifi.sh

[Install]
WantedBy=multi-user.target
WU
ln -sf ../y700-wifi.service "$R/etc/systemd/system/multi-user.target.wants/y700-wifi.service"
U "y700-wifi.service armed"
U "ath11k hw2.1 listing=[$(ls "$R/usr/lib/firmware/ath11k/WCN6855/hw2.1" 2>/dev/null | tr '\n' ',')]"
P "WIFI observer armed rebind=off"

# ---- 5. one diagnostic pass per boot: journal + card copy + weston fallback ----
mkdir -p "$R/usr/local/bin" 2>/dev/null
cat > "$R/usr/local/bin/y700-diag.sh" <<'DIAG'
#!/bin/sh
# A110: evidence collection inside the running system, twice per boot.
# The panel shows fbcon only while no compositor owns the display, and a reset
# can come before one late pass would run, so each pass is pushed to the card
# as soon as it is written.
K="Y700-A124-DIAG"
# kmsg as well as stdout: the panel console shows kernel messages, and a diag
# line that only reaches the journal is invisible with no card reader in hand.
P() { echo "<3>$K $*" > /dev/kmsg 2>/dev/null; echo "<3>$K $*"; }

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
        echo "-- systemd job state --"
        echo "get-default=$(systemctl get-default 2>&1) running=$(systemctl is-system-running 2>&1)"
        ls -l /etc/systemd/system/default.target /etc/systemd/system/display-manager.service 2>&1
        ls -l /etc/systemd/system/multi-user.target.wants/ 2>&1
        echo "-- jobs --"
        systemctl list-jobs --no-pager --plain 2>&1
        echo "job_count=$(systemctl list-jobs --no-legend --plain 2>/dev/null | grep -c .)"
        echo "-- units still working --"
        systemctl list-units --all --state=activating --state=waiting --no-legend --plain --no-pager 2>&1
        echo "-- the four units that matter --"
        for u in graphical.target display-manager.service sddm.service multi-user.target; do
            echo "@@ $u $(systemctl show "$u" -p LoadState,ActiveState,SubState,UnitFileState,JobType,JobMode,Result,ExecMainStatus,Followers 2>&1 | tr '\n' ' ')"
            systemctl status "$u" --no-pager -l 2>&1 | head -n 18
        done
        echo "-- what graphical.target waits on --"
        systemctl list-dependencies --after graphical.target --no-pager 2>&1 | head -n 45
        systemd-analyze critical-chain graphical.target --no-pager 2>&1 | head -n 25
        systemd-analyze critical-chain sddm.service --no-pager 2>&1 | head -n 25
        echo "-- systemd's own journal, heartbeat removed --"
        journalctl -b -t systemd --no-pager 2>&1 | grep -av 'Y700-' | tail -n 220
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
        echo "-- pci devices --"
        ls -l /sys/bus/pci/devices/ 2>&1
        for d in /sys/bus/pci/devices/*; do
            printf '%s vendor=%s device=%s subsystem=%s class=%s driver=%s\n' "${d##*/}" "$(cat "$d"/vendor 2>/dev/null)" "$(cat "$d"/device 2>/dev/null)" "$(cat "$d"/subsystem_device 2>/dev/null)" "$(cat "$d"/class 2>/dev/null)" "$(readlink "$d"/driver 2>/dev/null)"
        done
        echo "-- pcie host / pwrctrl / pwrseq platform devices --"
        ls /sys/bus/platform/devices/ 2>&1 | grep -aiE 'pcie|pwrctrl|pwrseq|1c00'
        ls -l /sys/bus/platform/drivers/ 2>&1 | grep -aiE 'pcie|pwrctrl|pwrseq'
        for p in /sys/devices/platform/*1c00000* /sys/devices/platform/*pwrctrl*; do
            [ -e "$p" ] || continue
            echo "@@ $p of_node=$(basename "$(readlink "$p/of_node" 2>/dev/null)" 2>/dev/null) driver=$(readlink "$p/driver" 2>/dev/null)"
        done
        echo "-- network interfaces / rfkill --"
        ip link 2>&1
        ls /sys/class/net 2>&1
        rfkill list 2>&1
        echo "-- nvt touch firmware on disk --"
        ls -ld /lib /usr/lib 2>&1
        ls -l /usr/lib/firmware/novatek /lib/firmware/novatek 2>&1
        for f in /usr/lib/firmware/novatek/lenovo-tb320fc.bin /lib/firmware/novatek/lenovo-tb320fc.bin; do
            [ -f "$f" ] && echo "present $f $(wc -c < "$f") $(sha256sum "$f" 2>/dev/null | cut -c1-16)"
        done
        echo "nvt-fw.done: $(cat /var/lib/y700/nvt-fw.done 2>&1)"
        echo "-- wifi: y700-wifi.service --"
        systemctl status y700-wifi.service --no-pager -l 2>&1 | head -n 24
        echo "-- wifi: unit journal --"
        journalctl -b -u y700-wifi.service --no-pager 2>&1 | tail -n 40
        echo "-- wifi: script log --"
        tail -n 60 /var/log/y700-wifi.txt 2>&1
        echo "-- panel connector state --"
        for c in /sys/class/drm/*; do
            [ -d "$c" ] || continue
            echo "$(basename "$c") enabled=$(cat "$c/enabled" 2>/dev/null) dpms=$(cat "$c/dpms" 2>/dev/null) status=$(cat "$c/status" 2>/dev/null)"
        done
        echo "vt_console=$(ls /sys/class/vtconsole 2>/dev/null | tr '\n' ',') fbcon_bind=$(cat /sys/class/vtconsole/vtcon1/bind 2>/dev/null)"
        echo "-- ath11k firmware on disk --"
        ls -lR /usr/lib/firmware/ath11k/WCN6855 2>&1
        echo "-- kernel: pci / ath11k / wcn / pwrseq --"
        journalctl -b -k --no-pager 2>&1 | grep -aiE 'pci|ath11k|wcn|17cb|pwrseq|pwrctrl|mhi|cfg80211|regdb|firmware|wifi|wlan|Y700-A124-WIFI' | tail -n 160
        echo "-- touch: spi binding, input nodes, irq, backlight --"
        ls -l /sys/bus/spi/drivers/ 2>&1 | grep -aiE 'novatek|spi'
        for d in /sys/bus/spi/drivers/*/spi*; do
            [ -e "$d" ] || continue
            echo "@@ $d of=$(basename "$(readlink "$d/of_node" 2>/dev/null)" 2>/dev/null) modalias=$(cat "$d/modalias" 2>/dev/null) spi-max=$(cat "$d/max_speed_hz" 2>/dev/null)"
        done
        for f in /sys/module/novatek_nt36523n_spi/parameters/*; do
            [ -f "$f" ] && echo "param ${f##*/}=$(cat "$f" 2>/dev/null)"
        done
        echo "-- /proc/interrupts --"
        cat /proc/interrupts 2>&1 | head -n 40
        echo "-- input devices --"
        cat /proc/bus/input/devices 2>&1
        for e in /sys/class/input/event*; do
            echo "$(basename "$e") name=$(cat "$e/device/name" 2>/dev/null) phys=$(cat "$e/device/phys" 2>/dev/null) uniq=$(cat "$e/device/uniq" 2>/dev/null)"
        done
        echo "-- who holds an input node --"
        for p in /proc/[0-9]*; do
            for f in "$p"/fd/*; do
                t=$(readlink "$f" 2>/dev/null) || continue
                case "$t" in /dev/input/*) echo "$(cat "$p"/comm 2>/dev/null) pid=${p#/proc/} $t";; esac
            done
        done 2>/dev/null | head -n 40
        echo "-- backlight --"
        for b in /sys/class/backlight/*; do
            echo "$(basename "$b") brightness=$(cat "$b/brightness" 2>/dev/null) max=$(cat "$b/max_brightness" 2>/dev/null) bl_power=$(cat "$b/bl_power" 2>/dev/null) actual=$(cat "$b/actual_brightness" 2>/dev/null)"
        done
        echo "-- kernel, nvt / panel / dpms / suspend --"
        journalctl -b -k --no-pager 2>&1 | grep -av 'Y700-' | grep -aiE 'nvt|nt36523|finger input|trim id|novatek|panel|dpms|backlight|suspend|resume|freez' | tail -n 120
        echo "-- touchd log tail --"
        tail -n 140 /var/log/y700-touchd.txt 2>&1
        echo "-- touchd key hits --"
        tail -n 40 /run/y700-keyhits 2>&1
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
    TP=$(awk '/spi[0-9]+[.][0-9]+/ { t = 0; for (i = 2; i <= NF; i++) { if ($i ~ /^[0-9]+$/) t += $i; else break } print t }' /proc/interrupts 2>/dev/null)
    BL=$(cat /sys/class/backlight/*/brightness 2>/dev/null | head -1)
    P "SUM$S jobs=$(systemctl list-jobs --no-legend --plain 2>/dev/null | grep -c .) running=$(systemctl is-system-running 2>&1) procs=[$PROCS] pci=[$(ls /sys/bus/pci/devices 2>/dev/null | tr '\n' ',')] net=[$(ls /sys/class/net 2>/dev/null | tr '\n' ',')] failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | grep -c .) vtbind=$(cat /sys/class/vtconsole/vtcon1/bind 2>/dev/null) dri=[$(ls /dev/dri 2>/dev/null | tr '\n' ',')] sess=$(loginctl list-sessions --no-legend --plain 2>/dev/null | grep -c .) tp=[$TP] bl=[$BL] ev=[$(ls /sys/class/input 2>/dev/null | grep -c "^event")]"
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
        mount -t vfat -o rw,sync "$d" /mnt/y700card 2>/dev/null || continue
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
    journalctl -b --no-pager 2>&1 | grep -av 'Y700-' | tail -n 400 > /mnt/y700card/y700-out/y700-journal.txt 2>/dev/null
    journalctl -b -u sddm -u y700-diag -u y700-desktop --no-pager 2>&1 | grep -av 'Y700-' | tail -n 300 > /mnt/y700card/y700-out/y700-sddm.txt 2>/dev/null
    journalctl -b -t systemd --no-pager 2>&1 | grep -av 'Y700-' | tail -n 400 > /mnt/y700card/y700-out/y700-systemd.txt 2>/dev/null
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
        # rc=124 means the job could not run at all inside the cap: that is a
        # pending-job / ordering problem, and the job list printed below names
        # the unit everything is queued behind.
        systemctl reset-failed sddm.service >/dev/null 2>&1
        OUT=$(timeout 25 systemctl start sddm.service 2>&1); RC=$?
        P "START sddm rc=$RC out=[$(printf '%s' "$OUT" | head -n 2 | tr '\n' ';')]"
        sleep 10
        P "after-sddm $(for u in sddm display-manager graphical.target; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done) jobs=$(systemctl list-jobs --no-legend --plain 2>/dev/null | grep -c .) running=$(systemctl is-system-running 2>&1)"
        systemctl list-jobs --no-pager --plain 2>&1 | head -n 20
        journalctl -b -u sddm --no-pager 2>&1 | grep -av 'Y700-' | tail -n 40
    fi
fi
if ! systemctl is-active --quiet sddm ; then
    # The default target never finished its job; finish it by hand and let
    # systemd say why it cannot.
    OUT=$(timeout 30 systemctl start graphical.target 2>&1); RC=$?
    P "START graphical.target rc=$RC out=[$(printf '%s' "$OUT" | head -n 2 | tr '\n' ';')]"
    sleep 10
    P "after-graphical $(for u in sddm display-manager graphical.target; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done) jobs=$(systemctl list-jobs --no-legend --plain 2>/dev/null | grep -c .)"
fi
if ! systemctl is-active --quiet sddm ; then
    if [ -e /etc/systemd/system/y700-desktop.service ] ; then
        P "FALLBACK sddm is dead, starting the weston session"
        systemctl start y700-desktop.service 2>&1 | head -n 3
        P "A124 WESTON-FALLBACK issued"
    else
        P "FALLBACK no y700-desktop.service to fall back to"
    fi
fi

I=0
while [ $I -lt 6 ] ; do
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
Description=Y700 A124 session diagnostics
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

if [ -z "$CARD" ] ; then
    P "RETRIEVE skipped: no mmc card in this boot"
else
    mkdir -p /mnt/card 2>/dev/null
    COK=""
    MERR=none
    for f in vfat ext4 ext2 ; do
        MERR=$(mount -t $f -o rw "$CARD" /mnt/card 2>&1) && { COK=$f; break; }
    done
    if [ -z "$COK" ] ; then
        P "RETRIEVE failed: $CARD not mountable err=[$(printf '%s' "$MERR" | head -n 2 | busybox tr '\n' ';')] parts=[$(ls /dev/mmcblk*p[0-9] 2>/dev/null | busybox tr '\n' ' ')]"
    else
        mkdir -p /mnt/card/y700-out 2>/dev/null
        if [ -s /tmp/pst ] ; then
            tail -c 500000 /tmp/pst > /mnt/card/y700-out/y700-pst-previous.txt 2>/dev/null
            busybox sync
            P "PST copied bytes=$(wc -c < /mnt/card/y700-out/y700-pst-previous.txt 2>/dev/null) hits=$(grep -aciE 'kernel panic|Unable to handle|Oops:|Internal error|Call trace|watchdog' /mnt/card/y700-out/y700-pst-previous.txt 2>/dev/null)"
            grep -aiE 'kernel panic|Unable to handle kernel|Oops:|Internal error|Call trace|watchdog' /mnt/card/y700-out/y700-pst-previous.txt 2>/dev/null | tail -n 12 | cut -c 1-170
        else
            P "PST /tmp/pst empty - no previous-boot console in ramoops"
        fi
        # Remove what the journal copies left on the card in A109-A112: dead weight
        # on a 501 MB FAT, and MB-level mmc traffic is what the boot dies on.
        rm -f /mnt/card/y700-out/journal.tar 2>/dev/null
        rm -rf /mnt/card/y700-out/journal 2>/dev/null
        N=0
        # y700-touchd.txt is the touch sample log: the whole
        # point of the round lives in this one file.
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
        } > /mnt/card/y700-out/a124-rootstate.txt 2>&1
        busybox sync
        busybox sync
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

# ---- 6a. the patch log itself, in the SAME boot ----
# Without this the round under test can only be read one boot later, and a boot
# that overruns the card loses the log completely - that is how A109 went blind.
if [ -n "$CARD" ] ; then
    mkdir -p /mnt/card2 2>/dev/null
    if mount -o rw,sync "$CARD" /mnt/card2 2>/dev/null ; then
        mkdir -p /mnt/card2/y700-out 2>/dev/null
        if cat "$LOG" > /mnt/card2/y700-out/y700-a124.txt 2>/dev/null ; then
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
P "A124 APPLIED"
exit 0
