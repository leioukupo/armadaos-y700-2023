#!/bin/bash
# A35 (this round).  Earlier rounds' comments below were only renumbered
# by the version bump; this block is the authoritative description.
#
# The console is NOT dead at 2.2 s: the last visible line of a recent boot was
# a marker from kernel_init_freeable(), and an older round scrolled as far as
# the 10 s heartbeat, so the panel prints for at least ten seconds.  What was
# missing is a page worth photographing.  Hence:
# 1. do_initcalls() prints one page about the SD path, then holds the screen
#    for four 12 s windows (Y700-PHOTO n/4).  Four passes also show whether the
#    deferred-probe list shrinks or is frozen.
# 2. dd.c prints the return code of every probe attempt for the watched devices
#    (8804000 SD host, f100000 TLMM, regulators-1).  "never bound" and "bound
#    but failed with -EPROBE_DEFER" are different bugs.
# 3. the SD OPP table loses its required-opps: they point at rpmhpd genpd
#    levels, and qcom-rpmhpd registers no OPP table for those, so the host
#    device can fail devm_pm_opp_of_add_table() and sdhci-msm then never
#    creates an mmc host.  sdhci-msm treats a missing OPP table as optional.
# 4. liveness without panel or card: y700_khb prints a heartbeat every 3 s with
#    a flag /init sets through debugfs (au=1 means userspace is up), and still
#    nothing reboots the board.
# A24 (photo, last page): LVL7 done 2.195457, Y700-INITCALLS-DONE 2.195577, then
# nothing - even the KERN_EMERG run-init marker never appeared.  So the box dies
# between do_basic_setup() and run_init_process().  The old 9.255727 "death
# point" was only the 8 s level-0 msleep: with msleep(2000) all initcalls are
# done at 2.19 s (they cost ~0.2 s), and the panel survives the late group now
# that regulator_init_complete is blacklisted.  A35 promotes freeable-done /
# async-done / markro-done to KERN_EMERG and adds basic-done, initramfs-done,
# conroot-done, rdinit acc, freeable-leave.
# A35 = A23 with the console muted, the late power-down group blacklisted and the
# answer moved to /init.
# A23 walked the level-7 tail fine (photo 21.60 s, bpf/tcp_congestion), so the
# old 9.255727 silent point is behind us; what kills the boot now is somewhere in
# the last few initcalls or right after run-init, and a 190 page log cannot be
# photographed.  A35 mutes the panel to KERN_EMERG..KERN_ERR (no ignore_loglevel,
# loglevel=4) while initcall_debug stays in a 1 MiB log buffer (LOG_BUF_SHIFT 20),
# blacklists clk_disable_unused/genpd_power_off_unused/regulator_init_complete
# (late_initcall_sync: they power down everything ABL left on that Linux has no
# driver for - display rails first of all), prints the level beacon at EMERG, and
# has /init grep dmesg for the regulator/rpmh lines, the regulator/blk/mmc counts
# and the last 8 records as the last page before a 300 s hold.
# A35 = A22 with the level-0 park removed, plus the token bump.
# A22 (y700_pause=0) moved the same log from 219.9 s to 9.25 s of uptime, and
# deferred_probe_initcall from 10856396 usecs to 110006 usecs, so the 212-220 s
# "deaths" were the page-pause mdelay, not a hang, and the box now has ~200 s of
# slack before the firmware resets it.  Two consequences: (a) the real death
# point - the log always stops around the level-7 deferred probes, ~9.26 s - is
# now something we can instrument instead of race; (b) do_initcalls() no longer
# gets to reach /init at all from the 3rd boot of an image, because level 0 calls
# y700_ramlog_park(), which never returns.  A35 holds the replayed previous-boot
# tail on the panel for 20 s at level 0 and then boots for real, so each round
# gives two readable screens: the previous boot's last lines (survives a panel
# that died early, because the ramlog ring lives in DRAM and crosses the reset),
# and this boot's /init digest.
# A35 = A21 with one change and it is about wall clock, not about drivers.
# Every A1x/A2x round "died" at 212-220 s of uptime with the panel frozen on a
# page whose header we print ourselves ("== p186 stk 4/16 ==").  That number is
# our own page counter, and simplefb_new_page() does mdelay(y700_pause_ms) per
# page with y700_pause defaulting to 1200 ms: 186 pages = 223 s.  So the boot was
# not hung at all - it spent ~90% of the ABL watchdog window asleep inside the
# console driver, waiting to be photographed, and the firmware reset it while it
# was still printing.  With y700_pause=0 the same log renders in seconds, which
# is the first chance this port has had to actually reach the end of the initcall
# levels and run /init.  Photographing still works: the last page simply stays on
# the panel once output stops, and the ramlog mirror replays the previous boot's
# tail at level 0 of the next boot.
# /init now reaches its digest+hold screen in ~30 s instead of ~150 s, so even a
# hard firmware reset at ~220 s leaves a long readable window, and each line
# carries the uptime so the next photos can date the reset precisely.
# A35 = A1w with the instrument made real (no new driver behaviour changes).
# A1w never showed a previous-boot tail, and there were two independent reasons:
# register_console() clears CON_ENABLED for a non-boot console, so the A1t mirror
# may have been handed nothing; and the ring sat in DRAM that only our DTB
# reserves, which the board firmware is free to reuse over a watchdog reset.
# A35 mirrors printk records from console_emit_next_record() instead of
# registering a console, and writes three rings at once - A 0x9f500000 inside
# the firmware-owned camera_region (no-map, mapped with memremap), B 0xa7000000
# plain low DRAM reserved by our DTB, C 0xf0200000 the A1w spot - printing every
# ring header with pr_emerg plus a per-level status line, so one photo of an
# early page says whether the ring survives the reset and whether the mirror is
# fed at all.  Park now repeats the tail page every 20 s.
# A1w = A1u plus the first real attempt at the bandwidth-vote hang, plus a way
# to read the result without anyone standing next to the tablet:
#  * bcm-voter.c: qcom_icc_bcm_voter_commit() returns before generating any
#    AMC/TCS command, so no RPMh bandwidth vote ever reaches the RSC.  Every
#    hang so far sits right where a vote is committed (A1r died in the aggre2
#    provider, A1t right after the aggre1/system/pcie-anoc probes returned 0),
#    and providers/nodes/paths still register so ufs-qcom and qcom_scm keep
#    probing normally instead of failing on a missing path.
#  * y700_ramlog.c: after the first two real boots of a fresh image, init parks
#    itself at level 0 and re-prints the tail of the previous boot every 45 s.
#    CPU idles, panel holds one page => an unattended overnight run still shows
#    the killer lines in the morning (press-and-hold power to escape).
#
# A1u = A1t plus two readability fixes: the previous-boot replay now also runs
# at initcall level 0 (so it is the FIRST thing on the panel) and init sleeps
# 8 s right after it, freezing that page long enough to photograph.  The frozen
# screen then holds the last ~22 console lines of the PREVIOUS boot, even when
# that boot killed the display - the ramlog console saw them regardless.
#
# A1t = A1s plus an instrument that makes the death readable: the console
# output of a boot is mirrored into a 1 MiB ring in free DRAM
# (y700log@f0200000, reserved WITHOUT no-map so it stays in the linear map)
# and cleaned to the Point of Coherence, so it survives the ABL watchdog
# reset that follows.  init/main.c replays the last 24 lines of the PREVIOUS
# boot at the start of initcall levels 4..7, which is exactly where a dying
# boot goes silent - so the screen shows the killer even when this boot dies
# at the same place and the panel goes dark.  initcall_debug is now on as
# well, which names the initcall on the last page all by itself. the aggre2-noc provider
# (interconnect@1700000, phandle 0x2f) is pinned off in the boot DTB and all 38
# `interconnects` properties referencing it are deleted, because A1r died ~10 ms
# into "Y700-PROBE 1700000.interconnect".  That probe does no MMIO (no qcom_icc_desc
# .config for sm8450), so the killer is the RPMh bandwidth-vote side of icc rather
# than a register poke; removing the consumers' references keeps sdhci-msm, the
# GENI SEs, qcom_scm and crypto from deferring behind a provider that will never
# register.  qcom_scm.c is patched locally so a missing path means "no votes".
set -uo pipefail
K=/tmp/y700/kbuild/asphalt-linux
B=/tmp/y700/a1
CMD='earlycon=simplefb keep_bootcon nokaslr loglevel=4 initcall_debug consoleblank=0 clk_ignore_unused pd_ignore_unused no_console_suspend panic=0 softlockup_panic=1 watchdog_thresh=4 hung_task_panic=1 deferred_probe_timeout=0 y700_pause=0 initcall_blacklist=clk_disable_unused,genpd_power_off_unused,regulator_init_complete'
echo "=== a35 start $(date -u) ==="
chmod 755 /tmp/y700/initramfs/init
[ -x /tmp/y700/initramfs/init ] || { echo INIT_NOT_EXEC_SRC; exit 1; }
grep -q 'Y700-INIT-REACHED-A35' /tmp/y700/initramfs/init || { echo INIT_HACK_MISSING; exit 1; }
cp -f "$K/.config" "$K/.config.a1p-saved" || exit 1

# PDC as built-in (it is an interrupt-parent/wakeup-parent provider for TLMM, so
# a module is as good as absent here).
"$K/scripts/config" --file "$K/.config" --enable RESET_QCOM_PDC || { echo CFG_TOOL_FAIL; exit 1; }
# A35: turn the silent death into a printed, held stack trace.  panic=0 keeps
# the panel up forever; watchdog_thresh=4 makes a stuck CPU report at ~8 s,
# before the board firmware resets the SoC.
"$K/scripts/config" --file "$K/.config" --enable SOFTLOCKUP_DETECTOR || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --enable DETECT_HUNG_TASK || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --enable HARDLOCKUP_DETECTOR || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable I2C_QCOM_GENI || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable I2C_QUP || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable SPI_QCOM_GENI || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable SPI_QUP || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable QCOM_GENI_SERIAL || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable QCOM_AOSS_QMP || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable SCSI_UFS_QCOM || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable SCSI_UFSHCD || { echo CFG_TOOL_FAIL; exit 1; }
"$K/scripts/config" --file "$K/.config" --disable SCSI_UFSHCD_PLATFORM || { echo CFG_TOOL_FAIL; exit 1; }
# A35: initcall_debug stays in the log buffer, so the buffer has to be big
# enough that /init can still read the whole boot back out of dmesg.
"$K/scripts/config" --file "$K/.config" --set-val LOG_BUF_SHIFT 20 || { echo CFG_TOOL_FAIL; exit 1; }
make -C "$K" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig || { echo OLDDEFCONFIG_FAIL; exit 1; }
grep -E "^CONFIG_SOFTLOCKUP_DETECTOR=|^CONFIG_HARDLOCKUP_DETECTOR=|^CONFIG_DETECT_HUNG_TASK=|^CONFIG_PANIC_TIMEOUT=" "$K/.config" || exit 1
grep -q "^CONFIG_I2C_QCOM_GENI=y" "$K/.config" && { echo I2C_QCOM_GENI_STILL_ON; exit 1; }
grep -q "^CONFIG_I2C_QUP=y" "$K/.config" && { echo I2C_QUP_STILL_ON; exit 1; }
grep -q "^CONFIG_SPI_QCOM_GENI=y" "$K/.config" && { echo SPI_QCOM_GENI_STILL_ON; exit 1; }
grep -q "^CONFIG_SPI_QUP=y" "$K/.config" && { echo SPI_QUP_STILL_ON; exit 1; }
grep -q "^CONFIG_QCOM_GENI_SERIAL=y" "$K/.config" && { echo QCOM_GENI_SERIAL_STILL_ON; exit 1; }
grep -q "^CONFIG_QCOM_AOSS_QMP=y" "$K/.config" && { echo QCOM_AOSS_QMP_STILL_ON; exit 1; }
grep -q "^CONFIG_SCSI_UFS_QCOM=y" "$K/.config" && { echo SCSI_UFS_QCOM_STILL_ON; exit 1; }
grep -q "^CONFIG_SCSI_UFSHCD=y" "$K/.config" && { echo SCSI_UFSHCD_STILL_ON; exit 1; }
grep -q "^CONFIG_SCSI_UFSHCD_PLATFORM=y" "$K/.config" && { echo SCSI_UFSHCD_PLATFORM_STILL_ON; exit 1; }
grep -E '^CONFIG_RESET_QCOM_PDC=|^CONFIG_RESET_CONTROLLER=|^CONFIG_CMDLINE_FORCE=|^CONFIG_PINCTRL_MSM=|^CONFIG_SCSI_UFS_QCOM=|^CONFIG_MMC_SDHCI_MSM=|^CONFIG_REGULATOR_QCOM_RPMH=' "$K/.config" || exit 1
grep -q '^CONFIG_RESET_QCOM_PDC=y' "$K/.config" || { echo PDC_NOT_BUILTIN; exit 1; }
grep -q '^CONFIG_CMDLINE_FORCE=y' "$K/.config" || { echo CMDLINE_FORCE_LOST; exit 1; }
# local hacks this round depends on: the probe notes, the level marks and the
# optional-ICC qcom_scm patch (without it the scm node, whose interconnects we
# strip, would fail probe outright instead of just skipping bandwidth votes).
grep -q 'Y700: running without interconnect path' "$K/drivers/firmware/qcom/qcom_scm.c" || { echo SCM_HACK_MISSING; exit 1; }
diff -u "$K/.config.a1p-saved" "$K/.config" > /tmp/y700/a1/config-a35.diff; echo "config diff lines: $(wc -l < /tmp/y700/a1/config-a35.diff)"
sed -n '1,40p' /tmp/y700/a1/config-a35.diff

python3 - "$CMD" <<'PY' || { echo CFG_FAIL; exit 1; }
import re, sys
new = 'CONFIG_CMDLINE="%s"' % sys.argv[1]
p = '/tmp/y700/kbuild/asphalt-linux/.config'
s = open(p).read()
s2, n = re.subn(r'(?m)^CONFIG_CMDLINE=".*$', new, s, count=1)
assert n == 1 and 'deferred_probe_timeout=0' in s2 and 'initcall_debug' in s2
open(p, 'w').write(s2)
PY
grep -n '^CONFIG_CMDLINE' "$K/.config" || exit 1
grep -q 'y700_pause=0' "$K/.config" || { echo PAUSE_PARAM_MISSING; exit 1; }
grep -q '^CONFIG_LOG_BUF_SHIFT=20$' "$K/.config" || { echo LOG_BUF_TOO_SMALL; exit 1; }
grep -q 'loglevel=4' "$K/.config" || { echo LOGLEVEL_NOT_MUTED; exit 1; }
grep -q 'ignore_loglevel' "$K/.config" && { echo CONSOLE_STILL_UNFILTERED; exit 1; }
grep -q 'initcall_blacklist=clk_disable_unused,genpd_power_off_unused,regulator_init_complete' "$K/.config" || { echo BLACKLIST_MISSING; exit 1; }
grep -n 'y700_probe_note' "$K/drivers/base/dd.c" || { echo DD_HACK_MISSING; exit 1; }
grep -n 'Y700-LVL\|Y700-INITCALLS-DONE\|Y700-MARK run-init' "$K/init/main.c" || { echo MAIN_HACK_MISSING; exit 1; }
# A1t: the previous-boot log replay instrument must be wired in.
[ -f "$K/init/y700_ramlog.c" ] || { echo RAMLOG_SRC_MISSING; exit 1; }
grep -q 'y700_ramlog.o' "$K/init/Makefile" || { echo RAMLOG_NOT_IN_MAKEFILE; exit 1; }
grep -q 'msleep(2000)' "$K/init/main.c" || { echo TAIL_HOLD_MISSING; exit 1; }
grep -q 'Y700-MARK basic-done' "$K/init/main.c" || { echo BISECT_MARKERS_MISSING; exit 1; }
grep -q '^CONFIG_MMC_DEBUG=y$' "$K/.config" || { echo MMC_DEBUG_NOT_SET; exit 1; }
grep -q 'void y700_dump_devices(void)' "$K/drivers/base/dd.c" || { echo BIND_DUMP_MISSING; exit 1; }
grep -q 'emergency_restart' "$K/init/main.c" && { echo KHB_STILL_REBOOTS; exit 1; }
grep -q 'sysrq-trigger' /tmp/y700/initramfs/init && { echo INIT_STILL_USES_SYSRQ; exit 1; }
grep -q "^MNT=$" /tmp/y700/initramfs/init && { echo INIT_MNT_QUOTE_BUG; exit 1; }
grep -q '^CONFIG_DEBUG_FS=y' "$K/.config" || { echo DEBUG_FS_MISSING; exit 1; }
grep -q 'y700_watch_name' "$K/drivers/base/dd.c" || { echo PROBE_WATCH_MISSING; exit 1; }
grep -q 'Y700-PROBE-R' "$K/drivers/base/dd.c" || { echo PROBE_RESULT_PRINT_MISSING; exit 1; }
grep -q 'Y700-HB' "$K/init/main.c" || { echo HEARTBEAT_MISSING; exit 1; }
grep -q 'Y700-PHOTO' "$K/init/main.c" || { echo PHOTO_HOLD_MISSING; exit 1; }
grep -q 'debugfs_create_u32' "$K/init/main.c" || { echo ALIVE_FLAG_MISSING; exit 1; }
grep -q '/sys/kernel/debug/y700_alive' /tmp/y700/initramfs/init || { echo ALIVE_FLAG_WRITE_MISSING; exit 1; }
grep -q 'y700_khbfn' "$K/init/main.c" || { echo KHB_MISSING; exit 1; }
grep -q 'Y700-MARK rcu-done' "$K/init/main.c" || { echo RUN_BISECT_MARKERS_MISSING; exit 1; }
grep -q 'Y700-A35-HOLD-NO-REBOOT' "/tmp/y700/initramfs/init" || { echo A35_HOLD_MISSING; exit 1; }
grep -q 'exec /bin/busybox switch_root /mnt/root /init' "/tmp/y700/initramfs/init" || { echo A35_SWITCH_ROOT_MISSING; exit 1; }
grep -q 'A35 SWITCH_ROOT_TO' "/tmp/y700/initramfs/init" || { echo A35_SWITCH_MARKER_MISSING; exit 1; }
grep -q 'chroot /mnt/root /bin/busybox true' "/tmp/y700/initramfs/init" || { echo A35_CHROOT_GUARD_MISSING; exit 1; }
[ -f /tmp/y700/rootfs/init-root.sh ] || { echo ROOT_INIT_SRC_MISSING; exit 1; }
sh -n /tmp/y700/initramfs/init || { echo INIT_SYNTAX_BROKEN; exit 1; }
sh -n /tmp/y700/rootfs/init-root.sh || { echo ROOT_INIT_SYNTAX_BROKEN; exit 1; }
grep -q 'y700_ramlog_park();' "$K/init/main.c" && { echo STILL_PARKS_AT_LEVEL0; exit 1; }
grep -q 'Y700: RPMh bandwidth votes disabled' "$K/drivers/interconnect/qcom/bcm-voter.c" || { echo ICC_VOTE_HACK_MISSING; exit 1; }
grep -q 'y700_ramlog_replay(' "$K/init/main.c" && grep -q 'msleep(2000)' "$K/init/main.c" || { echo RAMLOG_REPLAY_MISSING; exit 1; }
# A35: the mirror must be fed by printk itself, and the ring init must really
# land inside the __con_initcall_start..__con_initcall_end range (that is what
# console_init() walks).  A1w proved the range is walked - y7l_map was the first
# entry there - so this check has to keep passing.
grep -q 'y700_ramlog_store(outbuf, pmsg.outbuf_len, pmsg.seq);' "$K/kernel/printk/printk.c" || { echo PRINTK_HOOK_MISSING; exit 1; }
grep -q 'console_initcall(y7l_init);' "$K/init/y700_ramlog.c" || { echo RAMLOG_INITCALL_MISSING; exit 1; }
grep -q 'register_console(&' "$K/init/y700_ramlog.c" && { echo RAMLOG_STILL_REGISTERS_CONSOLE; exit 1; }
grep -q 'Y700-RAMLOG status' "$K/init/main.c" || { echo RAMLOG_STATUS_MISSING; exit 1; }
grep -q '0x9f500000' "$K/init/y700_ramlog.c" || { echo RAMLOG_RING_A_MISSING; exit 1; }
grep -q '0xa7000000' "$K/init/y700_ramlog.c" || { echo RAMLOG_RING_B_MISSING; exit 1; }
dtbout=$(Y700_MINIMAL=1 python3 "$B/mk_a1_dtb.py" 2>&1) || { echo DTB_FAIL; exit 1; }
printf '%s\n' "$dtbout"
printf '%s\n' "$dtbout" | grep -q 'A34: sd node dropped cd-gpios' || { echo SD_CDTOPOUT_APPLIED_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A29: dropped' || { echo SD_OPP_DROP_APPLIED_MISSING; exit 1; }
printf '%s\n' "$dtbout" | grep -q 'A33: pinned' || { echo SMP2P_DISABLE_APPLIED_MISSING; exit 1; }
cp -f "$B/a1.dtb" "$B/e15/e15.dtb" || exit 1
cp -f "$B/a1.dtb.info" "$B/e15/e15.dtb.info" || exit 1
"$K/scripts/dtc/dtc" -I dtb -O dts "$B/a1.dtb" > "$B/chk_a35.dts" || { echo DTC_FAIL; exit 1; }
python3 "$B/chk_minimal.py" "$B/chk_a35.dts" || { echo CHK_FAIL; exit 1; }
grep -q 'interrupts-extended = <0x01 0x00 0x1e1 0x04>;' "$B/chk_a35.dts" || { echo SPMI_IRQ_NOT_REPARENTED; exit 1; }
grep -q 'interrupts-extended = <0xbe 0x01 0x04>;' "$B/chk_a35.dts" && { echo SPMI_STILL_ON_PDC; exit 1; }
grep -q 'non-removable;' "$B/chk_a35.dts" && { echo SD_STILL_NONREMOVABLE; exit 1; }
grep -q 'broken-cd;' "$B/chk_a35.dts" || { echo SD_BROKEN_CD_MISSING; exit 1; }
grep -q 'max-frequency = <0x17d7840>;' "$B/chk_a35.dts" || { echo SD_MAXFREQ_MISSING; exit 1; }
grep -q 'Y700-A34: SD DMA disabled' "$K/drivers/mmc/host/sdhci-msm.c" || { echo SD_PIO_HACK_MISSING; exit 1; }
nbroken=$(python3 "$B/refs.py" "$B/chk_a35.dts" 2>/dev/null | grep -c 'pinctrl@f100000')
[ "$nbroken" = "0" ] || { echo PINCTRL_STILL_BROKEN; exit 1; }
touch /tmp/y700/initramfs /tmp/y700/initramfs/init
cd "$K" || exit 1
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image || { echo BUILD_FAIL; exit 1; }
ls -l arch/arm64/boot/Image
ls -l drivers/reset/reset-qcom-pdc.o || { echo PDC_NOT_BUILT; exit 1; }
ls -l init/y700_ramlog.o || { echo RAMLOG_NOT_BUILT; exit 1; }
ls -l drivers/interconnect/qcom/bcm-voter.o || { echo BCM_VOTER_NOT_BUILT; exit 1; }
sha256sum arch/arm64/boot/Image
nm vmlinux > /tmp/y700/a1/nm-a35.txt || { echo NM_FAIL; exit 1; }
grep -q ' y700_ramlog_store$' /tmp/y700/a1/nm-a35.txt || { echo RAMLOG_STORE_NOT_LINKED; exit 1; }
grep -q ' y7l_console$' /tmp/y700/a1/nm-a35.txt && { echo RAMLOG_CONSOLE_STILL_LINKED; exit 1; }
grep -q '_y7l_initcon$' /tmp/y700/a1/nm-a35.txt || { echo RAMLOG_NOT_A_CON_INITCALL; exit 1; }
grep -q ' y700_dump_devices$' /tmp/y700/a1/nm-a35.txt || { echo BIND_DUMP_NOT_LINKED; exit 1; }
python3 - <<'PY' || { echo RAMLOG_NOT_IN_CON_RANGE; exit 1; }
import subprocess
out = subprocess.check_output(['nm', 'vmlinux'], cwd='/tmp/y700/kbuild/asphalt-linux').decode()
sym = {}
for ln in out.splitlines():
    p = ln.split()
    if len(p) == 3 and p[1] in ('d', 'D', 'b'):
        if p[2] in ('__con_initcall_start', '__con_initcall_end'):
            sym[p[2]] = int(p[0], 16)
        elif p[2].endswith('_y7l_initcon'):
            sym['y7l'] = int(p[0], 16)
assert 'y7l' in sym, 'ramlog is not in the console initcall list at all'
print('con_initcall 0x%x..0x%x  y7l_init at 0x%x'
      % (sym['__con_initcall_start'], sym['__con_initcall_end'], sym['y7l']))
assert sym['__con_initcall_start'] <= sym['y7l'] < sym['__con_initcall_end']
PY
grep -ac 'Y700-INIT-REACHED-A35' "$K/usr/initramfs_data.cpio" || { echo CPIO_STALE; exit 1; }
mode=$(cd "$K/usr" && cpio -tv < initramfs_data.cpio 2>/dev/null | awk '$NF == "init" {print $1}')
echo "cpio init mode: $mode"
case "$mode" in
  *x*) ;;
  *) echo CPIO_INIT_NOT_EXECUTABLE; exit 1 ;;
esac
cp -f arch/arm64/boot/Image "$B/armada-boot/vmlinuz" || exit 1
python3 "$B/mk_e15_stub.py" || { echo STUBGEN_FAIL; exit 1; }
aarch64-linux-gnu-as -o "$B/e15/e15_stub.o" "$B/e15/e15_stub.S" || { echo ASM_FAIL; exit 1; }
aarch64-linux-gnu-objcopy -O binary "$B/e15/e15_stub.o" "$B/e15/e15_stub.bin" || { echo OBJCOPY_FAIL; exit 1; }
python3 "$B/build_e15.py" "$B/out/boot-b-a35.img" || { echo PACK_FAIL; exit 1; }
cp -f "$B/out/boot-b-a35.img" /tmp/y700/e15/ || exit 1
ls -l /tmp/y700/e15/boot-b-a35.img
sha256sum /tmp/y700/e15/boot-b-a35.img
echo "=== a35 end $(date -u) ==="
echo A35_ALL_OK
