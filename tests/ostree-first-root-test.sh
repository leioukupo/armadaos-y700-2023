#!/usr/bin/env bash
# Gate test for devices/lenovo-tb320fc/rootfs/ostree-first-root.sh.
#
# That script adopts a flat UFS root image offline and then refuses to let the image go to
# the tablet unless its post-adoption gates pass. The first version of the gates was wrong
# in three ways that all pointed the other way, and silent in the one way that mattered:
#   - it grepped "ostree admin status" for the word "Deployment", which libostree never
#     prints (it lists "  <stateroot> <deploy-id>.0"), so a healthy sysroot failed;
#   - it looked for the boot farm under /ostree/boot.0, but BLS adoption writes loader.1
#     and the boot.1 farm - exactly what armada-ostree-stage1.sh and armada-ostree-bootlink
#     select by following the /boot/loader symlink;
#   - it measured the raw BLS options line, while the payload packer writes a different
#     string assembled by bootimg-args.
# The real problem (a cmdline that cannot fit the boot header's cmdline field) was reported
# as a bare number, with no hint that the cause was a root image without an initramfs.
#
# The gates are tested here without a 20 GB image: the patterns are read out of the script
# under test and run against captured real output, and the cmdline math goes through the
# same bootimg-args that make-bootimg.sh and armada-bootimg-update use.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/devices/lenovo-tb320fc/rootfs"
FIRST="${SRC_DIR}/ostree-first-root.sh"
LIB="${ROOT_DIR}/system_files/usr/lib/armada/bootimg-args"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

for f in "$FIRST" "$LIB"; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done
if bash -n "$FIRST"; then ok "ostree-first-root.sh parses"; else fail "ostree-first-root.sh does not parse"; fi

# ---- 1. the cmdline gate has to measure what the packer writes -----------------
if grep -q "system_files/usr/lib/armada/bootimg-args" "$FIRST"; then
    ok "the gate sources the shared bootimg-args"
else
    fail "the gate does not source bootimg-args; it is measuring its own copy of the rules"
fi
if grep -q "armada_bootimg_cmdline" "$FIRST"; then ok "the gate calls the packer's own transform"; else fail "the gate does not call armada_bootimg_cmdline"; fi
if grep -q "ARMADA_CMDLINE_MAX" "$FIRST"; then ok "the limit comes from the packer's constant"; else fail "the limit is hardcoded again"; fi
if grep -q "ABL takes at most 512" "$FIRST"; then fail "a hand-written 512 B message is still in the gate"; else ok "no hand-written 512 B message in the gate"; fi
for user in "post_process/make-bootimg.sh" "system_files/usr/libexec/armada/armada-bootimg-update"; do
    if grep -q "armada_bootimg_cmdline" "${ROOT_DIR}/${user}"; then
        ok "${user} builds the cmdline with the same function"
    else
        fail "${user} no longer uses armada_bootimg_cmdline; the three gates can drift"
    fi
done

# shellcheck disable=SC1090
source "${LIB}"
# The entry the a168 on-device adoption produced on HA1WZJJ5: the board tuning the payload
# has to keep, plus the ostree= pointer into the boot farm. That one booted.
GOOD_OPTS="root=PARTLABEL=y700root-ufs rootwait selinux=0 systemd.unit=multi-user.target console=tty0 iomem=relaxed nokaslr loglevel=4 consoleblank=0 clk_ignore_unused pd_ignore_unused no_console_suspend panic=0 softlockup_panic=1 watchdog_thresh=4 hung_task_panic=1 deferred_probe_timeout=0 y700_pause=0 initcall_blacklist=clk_disable_unused,genpd_power_off_unused,regulator_init_complete ostree=/ostree/boot.1/default/3bee8cf46f5404e5b9e08559ca05e192d29fb69f6f4e2f2fb1450ad42f22b159/0"
pay=$(armada_bootimg_cmdline "${GOOD_OPTS}")
if (( ${#pay} <= ARMADA_CMDLINE_MAX )); then
    ok "a real entry fits the header field: ${#pay} B of ${ARMADA_CMDLINE_MAX} B"
else
    fail "a real entry no longer fits the header field: ${#pay} B of ${ARMADA_CMDLINE_MAX} B"
fi
if [[ "${pay%% *}" == ostree=* ]]; then
    ok "ostree= still leads, so a truncated header loses tuning kargs, not the root pointer"
else
    fail "armada_bootimg_cmdline stopped putting ostree= first"
fi
# A root image without an initramfs makes libostree write its aboot shape instead of an
# initrd line, and the init= karg that comes with it is what pushed the first smoke over
# the limit. The gate has to tell those two cases apart.
CSUM=$(printf '%s' "${GOOD_OPTS}" | sed -n 's|.*ostree=/ostree/boot.1/default/\([0-9a-f]*\)/0.*|\1|p')
ABOOT_OPTS="${GOOD_OPTS} init=/ostree/boot.1/default/${CSUM}/0/usr/lib/ostree/ostree-prepare-root"
pay2=$(armada_bootimg_cmdline "${ABOOT_OPTS}")
if (( ${#pay2} > ARMADA_CMDLINE_MAX )); then
    ok "the init= shape really is over the limit: ${#pay2} B"
else
    fail "the init= shape now fits (${#pay2} B); the gate's no-initrd diagnosis is stale"
fi
if grep -q "^initrd " "$FIRST"; then
    ok "the gate checks for the initrd line before blaming the kargs"
else
    fail "the gate no longer looks at the initrd line"
fi

# ---- 2. the deployment gate has to match what libostree prints ------------------
status_re=$(sed -n "s/^STATUS_RE_TPL='\(.*\)'$/\1/p" "$FIRST")
if [ -z "${status_re}" ]; then
    fail "cannot read STATUS_RE_TPL out of $(basename "$FIRST")"
    status_re='^[[:space:]]+@STATEROOT@ [0-9a-f]+\.0'
fi
status_re=${status_re/@STATEROOT@/default}
# captured from a loop-mounted adopted image on the build machine
real_listing="  default 1466facb5a5b615ef2b4094d56defc04012d239d8d533f6f79bc32841fdd520e.0
    Version: 20261126.fake
    origin: <unknown origin type>"
if printf '%s\n' "${real_listing}" | grep -qE "${status_re}"; then
    ok "the deployment pattern matches a real ostree admin status listing"
else
    fail "the deployment pattern does not match what ostree admin status prints"
fi
if printf 'No such file or directory\nerror: This system is not an OSTree system\n' | grep -qE "${status_re}"; then
    fail "the deployment pattern also matches a sysroot with nothing deployed"
else
    ok "the deployment pattern rejects a sysroot with no deployment"
fi
if printf '%s\n' "${real_listing}" | grep -q "Deployment"; then
    fail "the fixture changed: the old grep for 'Deployment' would now pass, so it cannot be shown to be wrong"
else
    ok "the old grep for the word 'Deployment' really would have failed on this listing"
fi

# ---- 3. the boot farm version has to be derived, not assumed -------------------
farm_tpl=$(sed -n "s/^FARM_GLOB_TPL='\(.*\)'$/\1/p" "$FIRST")
if [ -z "${farm_tpl}" ]; then
    fail "cannot read FARM_GLOB_TPL out of $(basename "$FIRST")"
    farm_tpl='ostree/boot.@BOOTV@*/@STATEROOT@'
fi
# The farm shape an adopted sysroot really has (captured from the offline adoption):
#   /ostree/boot.1 -> boot.1.1
#   /ostree/boot.1.1/default/<bootcsum>/0 -> ../../../deploy/default/deploy/<id>.0
# The <bootcsum> entry is a directory and only the <treebootserial> inside it is a symlink,
# which is why a check for symlinks one level under the stateroot failed a good sysroot.
T=$(mktemp -d /tmp/armada-farm-XXXXXX)
CSUM=73cb3858a687a8494ca3323053016282f3dad39d42cf62ca4e79dda2aac7d9ac
DEPLOY=18d545a443f8c86334db77213bc76ce42a2a8c3bb3a83f78fcdf56e3c7269f33.0
mkdir -p "${T}/ostree/boot.1.1/default/${CSUM}" "${T}/ostree/deploy/default/deploy/${DEPLOY}"
ln -s "boot.1.1" "${T}/ostree/boot.1"
ln -s "../../../deploy/default/deploy/${DEPLOY}" "${T}/ostree/boot.1.1/default/${CSUM}/0"
farm=${farm_tpl/@BOOTV@/1}; farm=${farm/@STATEROOT@/default}
farm0=${farm_tpl/@BOOTV@/0}; farm0=${farm0/@STATEROOT@/default}
found=""
for cand in "${T}"/${farm}; do
    [ -d "${cand}" ] && found="${cand}"
done
if [ -n "${found}" ]; then
    ok "the derived boot.1 glob finds the stateroot the adoption wrote"
else
    fail "the derived boot.1 glob does not find the stateroot"
fi
if [ -n "$(find "${T}"/${farm0} -maxdepth 1 2>/dev/null)" ]; then
    fail "fixture problem: boot.0 matches too, so the old hardcoded version cannot be shown to be wrong"
else
    ok "the hardcoded boot.0 farm would have found nothing on this sysroot"
fi
if [ -n "$(find "${T}/ostree/boot.1/default" -mindepth 2 -maxdepth 2 -type l 2>/dev/null)" ]; then
    ok "the deployment link sits at <bootcsum>/<serial> under the stateroot"
else
    fail "fixture problem: the treebootserial link is not where libostree puts it"
fi
if [ -n "$(find "${T}/ostree/boot.1/default" -maxdepth 1 -type l 2>/dev/null)" ]; then
    fail "fixture problem: a link directly under default/ hides the maxdepth mistake"
else
    ok "symlinks one level under the stateroot really are absent (the old gate's error)"
fi
rm -rf "${T}"
# the gate has to read the ostree= path the same way the runtime does, or it can bless a
# link nothing will resolve
prog='s/.*ostree=\([^ ]*\).*/\1/p'
for f in armada-ostree-stage1.sh armada-ostree-bootlink.sh ostree-first-root.sh; do
    if grep -qF "${prog}" "${SRC_DIR}/${f}"; then
        ok "${f} extracts the farm path with the same sed program"
    else
        fail "${f} no longer extracts ostree= with 's/.*ostree=\\([^ ]*\\).*/\\1/p'"
    fi
done
for f in armada-ostree-stage1.sh armada-ostree-bootlink.sh ostree-first-root.sh; do
    if grep -q "loader\.1" "${SRC_DIR}/${f}"; then
        ok "${f} picks the bootversion from the /boot/loader symlink"
    else
        fail "${f} no longer derives the bootversion from /boot/loader"
    fi
done
if grep -q 'ostree/boot\.0/' "$FIRST"; then
    fail "a hardcoded /ostree/boot.0 path is back in the gate"
else
    ok "no hardcoded /ostree/boot.0 path in the gate"
fi

# ---- 4. --check-only has to parse, and must not need the adoption inputs -------
out=$("${FIRST}" /nonexistent-armada-root.img --check-only 2>&1)
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s\n' "${out}" | grep -q "no such image"; then
    ok "--check-only parses and stops at the image, before any bundle requirement"
else
    fail "--check-only is not accepted (rc=${rc}): ${out}"
fi

echo
if [ "${fails}" -eq 0 ]; then echo "OSTREE_FIRST_ROOT_TEST_OK"; else echo "OSTREE_FIRST_ROOT_FAILURES=${fails}"; fi
exit "${fails}"
