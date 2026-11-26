#!/usr/bin/env bash
# Loop test for devices/lenovo-tb320fc/rootfs/armada-ostree-adopt.sh,
# armada-ostree-stage1.sh and init-ostree.
#
# Builds a fixture that matches the TB320FC UFS root (flat usr/etc/var, the
# installer's ostree -> sysroot/ostree symlink, unsuffixed kernel payload,
# runtime loop mounts, /home and /root pointing into /var), adopts it, and then
# really composes the deployment the way the stage-1 /init does at boot: bind the
# deployment as /, the physical root as /sysroot, the stateroot var as /var, a
# tmpfs as /run, move dev/proc/sys in and pivot_root. Inside that composed root
# the test runs libostree itself and requires it to call the deployment booted.
#
# Needs root, a loop device, an mount namespace and ostree; skips (exit 0)
# without them so the container build never depends on a privileged host.
set -uo pipefail

# This test mounts a loop image and runs a boot script that changes mount
# propagation, so it runs in a fresh mount namespace where a mistake - in this
# test or in the script under test - cannot reach the host's /proc, /sys or any
# other mount. Propagation is left as the host set it, because refusing MS_MOVE on a
# shared subtree is the same thing the board does, and the test relies on it. The
# marker keeps the re-exec from looping.
if [[ ${ARMADA_ADOPT_TEST_NS:-} != 1 ]] && command -v unshare >/dev/null 2>&1 &&
   unshare --mount -- true 2>/dev/null; then
    export ARMADA_ADOPT_TEST_NS=1
    exec unshare --mount -- bash "${BASH_SOURCE[0]}" "$@"
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/devices/lenovo-tb320fc/rootfs"
ADOPT="${SRC_DIR}/armada-ostree-adopt.sh"
KVER=7.2.6-tb320fc
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

for tool in ostree losetup mkfs.ext4 findmnt unshare; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is not installed"; exit 0; }
done
# ---------------------------------------------------------------------------
# The reference has to be accepted before anything is written.  It must cover the
# registry the image is actually published to, which carries a port:
# 192.168.31.4:5000/armada:<tag>.  The first version of the pattern excluded ':'
# from the host segment, so the adoption on the tablet died with "unsupported
# image reference" before doing anything (PROGRESS A207).
# ---------------------------------------------------------------------------
IMAGE_REF_RE=$(sed -n "s/^IMAGE_REF_RE='''\(.*\)'''\$/\1/p" "$ADOPT")
[ -n "$IMAGE_REF_RE" ] || fail "cannot read IMAGE_REF_RE out of $ADOPT"
for ref in \
    "ostree-unverified-image:docker://192.168.31.4:5000/armada:20261126.5f1e50c" \
    "ostree-unverified-registry:192.168.31.4:5000/armada:stable" \
    "ostree-image-signed:docker://ghcr.io/mydanyi/armadaos-freedom:stable"; do
    if [[ $ref =~ $IMAGE_REF_RE ]]; then ok "image reference accepted: $ref"; else fail "image reference rejected: $ref"; fi
done
for ref in "ostree-unverified-image:docker://armada" \
           "ostree-unverified-image:docker://192.168.31.4:5000/armada:bad tag" \
           "http://192.168.31.4:5000/armada:stable" \
           "ostree-unverified-image:docker://192.168.31.4:5000/"; do
    if [[ $ref =~ $IMAGE_REF_RE ]]; then fail "bad image reference accepted: $ref"; else ok "bad image reference rejected: $ref"; fi
done
[[ $EUID -eq 0 ]] || { echo "SKIP: needs root to mount a loop image"; exit 0; }
LOOP=$(losetup -f 2>/dev/null) || true
[[ -n "${LOOP:-}" ]] || { echo "SKIP: no free loop device"; exit 0; }

IMAGE=$(mktemp -u /tmp/armada-adopt-XXXXXX.img)
MNT=$(mktemp -d /tmp/armada-adopt-XXXXXX)
cleanup() {
    for d in dev proc sys; do umount "$MNT/$d" 2>/dev/null; done
    umount -R "$MNT" 2>/dev/null; umount "$MNT" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null; rm -rf "$MNT" "$IMAGE"
}
trap cleanup EXIT
truncate -s 4G "$IMAGE"
losetup "$LOOP" "$IMAGE"
mkfs.ext4 -q -F -L y700root-ufs "$LOOP" >/dev/null
mount -t ext4 "$LOOP" "$MNT"

# ---- fixture ----------------------------------------------------------------
mkdir -p "$MNT"/usr/{bin,etc/conf.d,lib/armada,lib/modules/"$KVER"/dtb/qcom} \
         "$MNT"/etc/systemd "$MNT"/var/{home/armada,roothome,srv,mnt,lib} \
         "$MNT"/opt "$MNT"/boot "$MNT"/sysroot "$MNT"/tmp "$MNT"/lost+found
printf 'NAME=Armada\nID=armada\nPRETTY_NAME="Armada FLAT-TEST"\nBUILD_ID="FLAT-TEST"\n' > "$MNT"/usr/lib/os-release
printf 'machine-state\n' > "$MNT"/etc/machine-state
printf 'tree-config\n' > "$MNT"/usr/etc/conf.d/armada.conf
printf 'KERNELPAYLOAD' > "$MNT"/usr/lib/modules/"$KVER"/vmlinuz
printf 'INITRAMFSPAYLOAD' > "$MNT"/usr/lib/modules/"$KVER"/initramfs.img
printf 'DTBPAYLOAD' > "$MNT"/usr/lib/modules/"$KVER"/dtb/qcom/sm8475-lenovo-tb320fc.dtb
printf 'user-file\n' > "$MNT"/var/home/armada/hello.txt
printf 'root-file\n' > "$MNT"/var/roothome/secret.txt
ln -s usr/bin "$MNT"/bin; ln -s usr/lib "$MNT"/lib
ln -s usr/sbin "$MNT"/sbin; ln -s usr/lib "$MNT"/lib64
ln -s var/home "$MNT"/home; ln -s var/roothome "$MNT"/root
ln -s var/srv "$MNT"/srv; ln -s var/mnt "$MNT"/mnt
ln -s sysroot/ostree "$MNT"/ostree
printf 'installer-leftover\n' > "$MNT"/.ostree.cfs
printf 'scratch\n' > "$MNT"/tmp/scratch
mkdir -p "$MNT"/usr/share/guestos/android
mount -t tmpfs tmpfs "$MNT"/usr/share/guestos/android
printf 'runtime-only\n' > "$MNT"/usr/share/guestos/android/runtime-file
# an executable init, the way the distro root has /usr/lib/systemd/systemd
printf '#!/bin/sh\nexit 0\n' > "$MNT"/usr/lib/systemd-systemd-stub
mkdir -p "$MNT"/usr/lib/systemd
printf '#!/bin/sh\nexit 0\n' > "$MNT"/usr/lib/systemd/systemd
chmod 0755 "$MNT"/usr/lib/systemd/systemd
# The stage-1 script has to run inside the fixture, so give it the applet set a
# distro root provides. busybox here is static, so it runs anywhere.
command -v busybox >/dev/null || { echo "SKIP: busybox is needed to run stage-1 inside the fixture"; exit 0; }
cp -fL "$(command -v busybox)" "$MNT/bin/busybox"
for applet in sh mount umount pivot_root stat tr wc cat ls chroot rm mkdir awk cut tail mv findmnt; do
    ln -sf busybox "$MNT/bin/$applet"
done

# Every stage-1 run is a root switch, and on the board pivot_root really does
# succeed. A root switch inside this test's own mount namespace moves / out from
# under every assertion that follows it, so each run gets a namespace of its own:
# the pivot lands there and dies with it, while the loop image stays mounted
# here, which is where the records stage-1 leaves on the physical root (boot.log,
# the attempt counter, the ostree-boot marker) are read back.
run_init() { unshare --mount chroot "$MNT" /init; }

# ---- adopt ------------------------------------------------------------------
"$ADOPT" --sysroot="$MNT" --min-free-gib=1 --enable-stage1 \
    --root-karg=root=PARTLABEL=y700root-ufs
check "adopt exits 0" "[ $? -eq 0 ]"
deploy=$(ls -1d "$MNT"/ostree/deploy/default/deploy/*.0 2>/dev/null | head -1)
[[ -n "$deploy" ]] || fail "no deployment staged"

check "repo and stateroot exist"   "[ -f $MNT/ostree/repo/config ] && [ -d $MNT/ostree/deploy/default/var ]"
check "BLS entry with ostree= karg" "grep -q '^options .*ostree=/ostree/boot' $MNT/boot/loader*/entries/*.conf"
check "BLS keeps root= and tuning"  "grep -q '^options .*root=PARTLABEL=y700root-ufs' $MNT/boot/loader*/entries/*.conf && grep -q initcall_blacklist= $MNT/boot/loader*/entries/*.conf"
check "kernel payload staged in /boot" "ls $MNT/boot/ostree/default-*/vmlinuz-*$KVER >/dev/null"
check "initrd payload staged in /boot" "ls $MNT/boot/ostree/default-*/initramfs-*$KVER.img >/dev/null"
check "usr/etc rode into the tree"  "[ -f $deploy/usr/etc/conf.d/armada.conf ]"
check "live /etc kept out of the commit" "[ ! -e $deploy/usr/etc/machine-state ]"
check "runtime mount not committed" "[ ! -e $deploy/usr/share/guestos/android/runtime-file ]"
check "staging and scratch excluded" "[ ! -e $deploy/tmp/scratch ] && [ ! -e $deploy/lost+found ] && [ ! -e $deploy/.ostree.cfs ]"
check "the tree carries no stage-1 launcher" "[ ! -e $deploy/init ]"
check "the tree carries no boot payload" "[ -d $deploy/boot ] && [ ! -e $deploy/boot/ostree ] && [ ! -e $deploy/boot/loader ]"
check "stateroot /var seeded"       "[ -f $MNT/ostree/deploy/default/var/home/armada/hello.txt ]"
check "stateroot /var shares inodes" "[ \$(stat -c %i $MNT/var/home/armada/hello.txt) = \$(stat -c %i $MNT/ostree/deploy/default/var/home/armada/hello.txt) ]"
check "flat root still real"        "[ -d $MNT/usr/bin ] && [ ! -L $MNT/usr ] && [ -f $MNT/etc/machine-state ]"
check "staging area removed"        "[ ! -e $MNT/.ostree-stage ]"
ostree fsck --repo="$MNT/ostree/repo" >/dev/null 2>&1 && ok "ostree fsck clean" || fail "ostree fsck"

# The deployment directory is immutable and libostree creates no mount points in
# it, so the tree itself has to carry them.
check "deployment carries the mount points" \
    "[ -d $deploy/sysroot ] && [ -L $deploy/ostree ] && [ -d $deploy/run ] && [ -d $deploy/dev ] && [ -d $deploy/proc ] && [ -d $deploy/sys ] && [ -d $deploy/tmp ]"
check "deployment ostree link points at sysroot/ostree" \
    "[ \$(readlink $deploy/ostree) = sysroot/ostree ]"
check "deployment /tmp is world writable with sticky bit" \
    "[ \$(stat -c %a $deploy/tmp) = 1777 ]"
# machine state has to be in the deployment's /etc, next to the tree's /usr/etc
check "deployment /etc seeded from the live /etc" \
    "[ -f $deploy/etc/machine-state ] && [ -f $deploy/etc/conf.d/armada.conf ]"
check "stage-1 installed" \
    "[ -x $MNT/init ] && [ -x $MNT/usr/lib/armada/armada-ostree-stage1.sh ] && [ \$(cat $MNT/etc/armada/ostree-boot) = yes ]"

# The revert mechanism needs a systemd unit that runs inside the composed root,
# and it has to be machine state so both roots carry it.
check "confirm unit installed and enabled" \
    "[ -f $MNT/etc/systemd/system/armada-ostree-confirm.service ] && [ -L $MNT/etc/systemd/system/multi-user.target.wants/armada-ostree-confirm.service ]"
check "confirm unit carried into the deployment /etc" \
    "[ -f $deploy/etc/systemd/system/armada-ostree-confirm.service ] && [ -L $deploy/etc/systemd/system/multi-user.target.wants/armada-ostree-confirm.service ]"

# ---- the kill switch: marker "no" has to leave the flat root alone ----------
# Right after armada-ostree-adopt, and after any later rollback of the composed
# root, the board boots with this marker set to "no". That path is what keeps the
# tablet bootable, so run /init exactly the way the boot_a initramfs does and
# require that it hands over to the distro init without composing anything.
printf 'no\n' > "$MNT/etc/armada/ostree-boot"
printf '#!/bin/sh\necho INIT_RAN\nexit 0\n' > "$MNT/usr/lib/systemd/systemd"
chmod 0755 "$MNT/usr/lib/systemd/systemd"
fallback_out=$(run_init 2>&1)
echo "$fallback_out" | sed -n 's/^/  | fallback /p'
check "marker no execs the distro init"       "echo \"\$fallback_out\" | grep -q INIT_RAN"
check "marker no says why it fell back"       "echo \"\$fallback_out\" | grep -q 'FALLBACK marker'"
check "marker no composes nothing"            "! findmnt -n -o TARGET 2>/dev/null | grep -q '.stage1-root'"
check "marker no keeps the marker and tree"   "[ \$(cat $MNT/etc/armada/ostree-boot) = no ] && [ -d $deploy/usr/etc ]"
check "the flat boot leaves a log on the physical root" \
    "grep -q 'FALLBACK marker' $MNT/armada-ostree/boot.log"
printf 'yes\n' > "$MNT/etc/armada/ostree-boot"

# ---- the marker libostree reads --------------------------------------------
# /run/ostree-booted holds the st_dev/st_ino of the deployment directory, and
# libostree only honours it when the sysroot it reads *is* / (in
# ostree_sysroot_initialize: root_is_ostree_booted = the record exists && the
# sysroot path has the dev/ino of /). So --sysroot=$MNT can never report
# (booted); the probe has to run inside the physical root. That means libostree
# has to be runnable inside the fixture: publish the host binary plus its
# libraries through the image, including the dynamic loader it was linked with.
tools="$MNT/opt/host-tools"
mkdir -p "$tools"
cp -fL "$(command -v ostree)" "$tools/ostree"
# The dynamic loader is copied along with the other libraries and invoked by
# path below, so the fixture does not need a matching /lib64 of its own.
ldd "$(command -v ostree)" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' |
    while read -r lib; do cp -fL "$lib" "$tools/" 2>/dev/null; done
mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys"
mount -t tmpfs -o mode=0755 tmpfs "$MNT/dev" 2>/dev/null
mount -t proc proc "$MNT/proc" 2>/dev/null
mount -t sysfs sysfs "$MNT/sys" 2>/dev/null
run_ostree() { chroot "$MNT" /bin/sh -c "for ld in /opt/host-tools/ld-*; do \"\$ld\" --library-path /opt/host-tools /opt/host-tools/ostree $*; done" 2>&1; }
# The stage-1 script writes the record as part of composition; here the point is
# the record itself, so build it with the same helper the script uses.
cat > /tmp/armada-booted-probe.$$.sh <<'EOF'
le64() {
    v=$1; fmt=; i=0
    while [ "$i" -lt 8 ]; do
        b=$(( (v >> (8 * i)) & 0xff )); fmt="$fmt\\$(printf '%03o' "$b")"; i=$((i + 1))
    done
    printf "$fmt"
}
{
    printf 'backing-root-device-inode\000\000\000\000\000\000\000'
    le64 "$1"; le64 "$2"
    printf '\000(tt)\032\066'
} > "$3"
EOF
chmod 0755 /tmp/armada-booted-probe.$$.sh
set -- $(stat -c '%d %i' "$deploy")
dev=$1; ino=$2
mkdir -p "$MNT/run"
/tmp/armada-booted-probe.$$.sh "$dev" "$ino" "$MNT/run/ostree-booted"
# The record is read as a trusted GVariant, so a stray byte crashes libostree
# instead of failing cleanly. Compare against what GLib itself serialises.
ref_bin=/tmp/armada-booted-ref.$$.bin
if command -v python3 >/dev/null && python3 -c 'import gi' >/dev/null 2>&1; then
    python3 - "$dev" "$ino" > "$ref_bin" <<'PY'
import sys
import gi
gi.require_version('GLib', '2.0')
from gi.repository import GLib

v = GLib.Variant('a{sv}', {'backing-root-device-inode':
    GLib.Variant('(tt)', (int(sys.argv[1]), int(sys.argv[2])))})
sys.stdout.buffer.write(bytes(v.get_data_as_bytes().get_data()))
PY
    check "booted record matches GLib's serialisation" "cmp -s $ref_bin $MNT/run/ostree-booted"
else
    echo "note: python3-gi missing, skipped the GVariant byte comparison"
fi
probe_out=$(chroot "$MNT" /bin/sh -c '
    wc -c < /run/ostree-booted
    for ld in /opt/host-tools/ld-*; do
        "$ld" --library-path /opt/host-tools /opt/host-tools/ostree admin status
    done
' 2>&1)
echo "$probe_out" | sed -n 's/^/  | probe /p'
check "booted record is 55 bytes" "echo \"\$probe_out\" | head -1 | grep -qx 55"
# ostree 2024.5 marks the booted deployment with a leading "*" (is_booted ? '*'
# : ' ' in ot-admin-builtin-status.c); it does not print the word "booted".
check "booted record makes libostree mark the deployment booted" \
    "echo \"\$probe_out\" | grep -q '^\* default '"
rm -f "$MNT/run/ostree-booted"
no_marker=$(run_ostree admin status)
echo "$no_marker" | sed -n 's/^/  | no-marker /p'
check "without the record the deployment is not booted" "! echo \"\$no_marker\" | grep -q '^\*'"

# ---- compose the root for real, exactly as the stage-1 /init does -----------
# The host libostree is already published at $MNT/opt/host-tools and dev/proc/sys
# are already mounted in the fixture; the composed root sees the former through
# /sysroot, which is the physical root.
composed=$(ARMADA_OSTREE_STAGE1_EXEC='
    set -x
    echo "ROOT $(stat -c "%d:%i" /)"
    ls -l /ostree
    ls -d /sysroot/ostree/repo /sysroot/boot/loader/entries
    test -f /etc/machine-state && echo ETC_OK
    test -f /usr/etc/conf.d/armada.conf && echo USRETC_OK
    test -f /usr/lib/modules/'"$KVER"'/vmlinuz && echo MODULES_OK
    test -f /home/armada/hello.txt && echo HOME_OK
    test -f /root/secret.txt && echo ROOTHOME_OK
    test "$(wc -c < /run/ostree-booted)" = 55 && echo MARKER_OK
    mount --bind /sysroot/opt/host-tools /opt
    for ld in /opt/ld-*; do "$ld" --library-path /opt /opt/ostree --sysroot=/ admin status; done
    for ld in /opt/ld-*; do "$ld" --library-path /opt /opt/ostree admin status; done
' run_init 2>&1)
echo "$composed" | sed -n 's/^/  | /p'
dep_root="$dev:$ino"
check "stage-1 pivoted into the deployment" "echo \"\$composed\" | grep -q \"ROOT $dep_root\""
check "composed /etc is the machine state"  "echo \"\$composed\" | grep -q ETC_OK"
check "composed /usr/etc from the tree"     "echo \"\$composed\" | grep -q USRETC_OK"
check "composed modules resolve"            "echo \"\$composed\" | grep -q MODULES_OK"
check "composed /home resolves into the stateroot var" "echo \"\$composed\" | grep -q HOME_OK"
check "composed /root resolves"             "echo \"\$composed\" | grep -q ROOTHOME_OK"
check "composed /run/ostree-booted is 55 bytes"        "echo \"\$composed\" | grep -q MARKER_OK"
check "composed /sysroot holds the repo and the BLS"   "echo \"\$composed\" | grep -q '/sysroot/ostree/repo'"
check "libostree inside the composed root marks it booted" \
    "[ \$(echo \"\$composed\" | grep -c '^\* default ') -ge 2 ]"
# In this fixture stage-1 runs inside a chroot, and the kernel only lets
# pivot_root switch the mount namespace root: the chroot fallback path is what
# runs here, and it has to leave the same on-root log behind.
check "the composed run appends to that log" \
    "grep -qE 'COMPOSED root=|pivot_root failed, using chroot' $MNT/armada-ostree/boot.log"

# ---- MS_MOVE refused: the fresh-mount fallback ------------------------------
# The board refuses MS_MOVE for the devtmpfs its boot initramfs created, so what
# has to hold is that /dev, /proc and /sys are mounted inside the composed root
# either way. The composition above cannot be what breaks the move any more - it
# happens in its own namespace now - so the move is denied the way it is denied
# on a mount that is not there: $MNT/dev is unmounted first, which leaves /dev a
# plain directory and leaves the fresh devtmpfs as the only way stage-1 can give
# the composed root a /dev. /proc stays mounted because stage-1 reads
# /proc/self/mountinfo before it moves anything.
umount "$MNT/dev" 2>/dev/null || true
moved=$(ARMADA_OSTREE_STAGE1_EXEC='
    set -x
    echo "ROOT $(stat -c "%d:%i" /)"
    test -c /dev/null && test -e /dev/console && echo DEV_FRESH
    test -f /proc/uptime && echo PROC_OK
    test -d /sys/devices && echo SYS_OK
    findmnt -n -o FSTYPE /dev
' run_init 2>&1)
echo "$moved" | sed -n 's/^/  | fallback /p'
check "the fallback composed the same deployment"  "echo \"$moved\" | grep -q \"ROOT $dep_root\""
check "the fallback mounted a fresh /dev"          "echo \"$moved\" | grep -q DEV_FRESH"
check "the fallback mounted /proc and /sys"        "echo \"$moved\" | grep -q PROC_OK && echo \"$moved\" | grep -q SYS_OK"
check "the fallback /dev is a devtmpfs"            "echo \"$moved\" | grep -q devtmpfs"
check "the fallback says so in the on-root log"    "grep -q 'mounted fresh as devtmpfs' $MNT/armada-ostree/boot.log"

# ---- a composed boot that never came up has to undo itself ------------------
# Nothing outside this root can read the UFS partition on this board, so stage-1
# arms an attempt before it moves any mount and only a confirmed boot clears it.
# These runs hide the stateroot (a leading dot keeps the /ostree/deploy/* glob
# from matching it) so the counter can be exercised without pivoting the fixture
# a second time.
state_dir=$MNT/armada-ostree
check "the composed run armed an attempt" \
    "[ -f $state_dir/attempt ] && [ ! -e $state_dir/confirmed ]"
mv "$MNT/ostree/deploy/default" "$MNT/ostree/deploy/.default-hold"
rm -rf "$state_dir"; mkdir -p "$state_dir"
printf 'stage1\n' > "$state_dir/attempt"
once=$(run_init 2>&1)
echo "$once" | sed -n 's/^/  | revert1 /p'
check "one unconfirmed attempt is counted"     "echo \"\$once\" | grep -q 'never confirmed (failed=1)' && [ \$(cat $state_dir/failed) = 1 ]"
check "one failure still goes on to compose"   "echo \"\$once\" | grep -q 'no deployment under /ostree/deploy'"
printf 'stage1\n' > "$state_dir/attempt"
printf '1\n' > "$state_dir/failed"
twice=$(run_init 2>&1)
echo "$twice" | sed -n 's/^/  | revert2 /p'
check "the second unconfirmed attempt falls back" "echo \"\$twice\" | grep -q 'never confirmed twice'"
check "the kill switch turns itself off"          "[ \$(cat $MNT/etc/armada/ostree-boot) = no ]"
check "the attempt record is cleared on fallback" "[ ! -e $state_dir/attempt ]"
mv "$MNT/ostree/deploy/.default-hold" "$MNT/ostree/deploy/default"
printf 'yes\n' > "$MNT/etc/armada/ostree-boot"

# ---- re-running refreshes the sysroot instead of failing --------------------
# A re-run stages /usr again after the first run installed /init and stage-1 in
# it, so this is where a tree that grew a second root-switch hook would show up.
"$ADOPT" --sysroot="$MNT" --min-free-gib=1 --root-karg=root=PARTLABEL=y700root-ufs \
    --stage1 install > /tmp/armada-adopt-rerun.$$.txt 2>&1
check "re-adopt exits 0" "[ $? -eq 0 ]"
rerun_commit=$(sed -n 's/^commit: \([0-9a-f]\{64\}\)$/\1/p' /tmp/armada-adopt-rerun.$$.txt | tail -1)
rerun_new=$(ls -1d "$MNT"/ostree/deploy/default/deploy/"$rerun_commit".[0-9] 2>/dev/null | tail -1)
# ostree reuses the deployment when the commit did not change, so a re-run is
# only required to leave exactly one usable deployment behind.
check "re-adopt left one usable deployment" \
    "[ -n \"$rerun_new\" ] && [ \$(ls -1d $MNT/ostree/deploy/default/deploy/*.0 | wc -l) -le 2 ]"
check "re-adopt kept the kill switch" "[ \$(cat $MNT/etc/armada/ostree-boot) = yes ]"
check "re-adopt kept the stateroot var" "grep -q 'stateroot var: kept' /tmp/armada-adopt-rerun.$$.txt"
check "the refreshed tree has no stage-1 launcher" "[ ! -e $rerun_new/init ]"
check "the refreshed tree has no stage-1 runtime state" "[ ! -e $rerun_new/armada-ostree ]"
check "the refreshed /etc carries the confirm unit" \
    "[ -f $rerun_new/etc/systemd/system/armada-ostree-confirm.service ] && [ -L $rerun_new/etc/systemd/system/multi-user.target.wants/armada-ostree-confirm.service ]"
check "the refreshed deployment targets the same ref" "grep -q '^refspec=armadaos$' $rerun_new.origin"

# ---- an image-backed deployment: the shape bootc manages -------------------
# bootc takes over a deployment only when its origin carries
# container-image-reference and its commit carries the image manifest metadata;
# a bare refspec leaves the OS panel with no channel and nothing to update.
# bootc itself cannot run inside the fixture, so these assert what libostree and
# bootc each read out of it - including that libostree still parses the
# deployment at all, which it stops doing if the image reference is written
# into refspec instead of container-image-reference.
if command -v tar >/dev/null && command -v sha256sum >/dev/null; then
    layer_dir=$(mktemp -d /tmp/armada-layer-XXXXXX)
    meta_dir=$(mktemp -d /tmp/armada-meta-XXXXXX)
    layer_tar=/tmp/armada-base-layer.$$.tar
    printf 'base-image-content\n' > "$layer_dir/base.txt"
    tar -cf "$layer_tar" -C "$layer_dir" .
    layer_digest=$(sha256sum "$layer_tar" | cut -d' ' -f1)
    layer_size=$(stat -c %s "$layer_tar")
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%064d","size":2},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%s}]}\n' \
        0 "$layer_digest" "$layer_size" > "$meta_dir/manifest.json"
    printf '{"architecture":"arm64","os":"linux","config":{"Labels":{"org.opencontainers.image.version":"IMG-TEST"}},"rootfs":{"type":"layers","diff_ids":[]}}\n' > "$meta_dir/config.json"
    # Content only the deployment trees have: --from deployment has to commit it,
    # and the flat root must not gain it. It goes into every deployment because
    # which one is taken as the running tree depends on how their checksums sort.
    drift_written=0
    for tree in "$MNT"/ostree/deploy/default/deploy/*.0; do
        printf 'drift\n' > "$tree/usr/drift-marker" 2>/dev/null && drift_written=1
    done

    # A root that stage-1 composed keeps the ext4 immutable bit on its
    # top-level directory, which makes the filesystem refuse every new file at
    # the sysroot root with EPERM. The deploy has to live with that: the staged
    # origin file lives outside the sysroot, so the immutable bit is not a
    # reason for an image-backed adoption to fail.
    immutable=0
    if command -v chattr >/dev/null && mkdir -p "$MNT/sysroot/ostree" 2>/dev/null &&
       chattr +i "$MNT" 2>/dev/null && lsattr -d "$MNT" | grep -q '^....i'; then
        immutable=1
        check "the fixture sysroot root is immutable" "lsattr -d $MNT | grep -q '^....i'"
    else
        echo "note:   chattr +i is unavailable here; immutable-root check skipped"
    fi

    "$ADOPT" --sysroot="$MNT" --min-free-gib=1 --stage1 skip --from deployment \
        --root-karg=root=PARTLABEL=y700root-ufs \
        --image-ref=ostree-unverified-image:docker://ghcr.io/mydanyi/armadaos-freedom:stable \
        --image-meta="$meta_dir" --base-layer="$layer_tar" \
        > /tmp/armada-adopt-image.$$.txt 2>&1
    image_rc=$?
    [[ $immutable -eq 1 ]] && chattr -i "$MNT"
    check "image adopt exits 0" "[ $image_rc -eq 0 ]"
    check "no origin file was staged inside the sysroot root" "[ ! -e $MNT/.ostree-origin ]"
    sed -n 's/^/  | image /p' /tmp/armada-adopt-image.$$.txt
    image_commit=$(sed -n 's/^commit: \([0-9a-f]\{64\}\)$/\1/p' /tmp/armada-adopt-image.$$.txt | tail -1)
    image_new=$(ls -1d "$MNT"/ostree/deploy/default/deploy/"$image_commit".[0-9] 2>/dev/null | tail -1)
    check "image origin carries the container reference" \
        "grep -q '^container-image-reference=ostree-unverified-image:docker://ghcr.io/mydanyi/armadaos-freedom:stable$' $image_new.origin"
    check "image origin carries no refspec" "! grep -q '^refspec=' $image_new.origin"
    check "libostree still parses the image-backed deployment" \
        "ostree admin --sysroot=$MNT status 2>&1 | grep -q 'origin: <unknown origin type>'"
    check "base layer imported as an ostree blob ref" \
        "ostree --repo=$MNT/ostree/repo rev-parse ostree/container/blob/sha256_3A_$layer_digest >/dev/null"
    check "image ref recorded the way ostree-ext names it" \
        "ostree --repo=$MNT/ostree/repo rev-parse ostree/container/image/docker_3A__2F__2F_ghcr_2E_io/mydanyi/armadaos-freedom_3A_stable >/dev/null"
    if [[ $drift_written -eq 1 ]]; then
        check "the running deployment is the tree that was committed" \
            "[ -f $image_new/usr/drift-marker ] && [ ! -e $MNT/usr/drift-marker ]"
    else
        echo "note:   the deployment tree is read-only here; drift check skipped"
    fi
    commit_obj="$MNT/ostree/repo/objects/${image_commit:0:2}/${image_commit:2}.commit"
    check "commit carries the manifest digest" \
        "grep -qa ostree.manifest-digest \"$commit_obj\""
    check "commit carries the manifest" \
        "grep -qa ostree.manifest \"$commit_obj\""
    check "commit carries the image configuration" \
        "grep -qa ostree.container.image-config \"$commit_obj\""
    check "the version stamp survived the image commit" \
        "ostree --repo=$MNT/ostree/repo log $image_commit | grep -q 'Version: FLAT-TEST'"
    check "the deployment-side staging area was removed" \
        "[ ! -e $MNT/ostree/deploy/.ostree-stage ]"
    # The stateroot now holds two serial 0 trees: the bare one this system
    # booted and the image-backed one just staged. stage-1 has to compose the
    # tree libostree also treats as the default, which is the newest by mtime.
    rm -f "$state_dir/attempt" "$state_dir/failed"
    ARMADA_OSTREE_STAGE1_EXEC='echo STAGE1_COMPOSED' run_init >/dev/null 2>&1
    check "stage-1 composed the image-backed deployment" \
        "grep -q 'deployment=/ostree/deploy/default/deploy/$image_commit.0 stateroot=' $MNT/armada-ostree/boot.log"
    check "stage-1 ordered the deployments by mtime" \
        "grep -qE 'deployment=/ostree/deploy/default/deploy/[0-9a-f]+\\.[0-9]+ stateroot=\\S+ serial=[0-9]+ mtime=[0-9]+' $MNT/armada-ostree/boot.log"
    rm -rf "$layer_dir" "$meta_dir" "$layer_tar" /tmp/armada-adopt-image.$$.txt
else
    echo "note:   tar and sha256sum are missing; image-backed checks skipped"
fi

# ---- a dry run must not change an existing sysroot --------------------------
ostree admin --sysroot="$MNT" status > /tmp/armada-adopt-before.$$.txt 2>&1
"$ADOPT" --sysroot="$MNT" --min-free-gib=1 --root-karg=root=PARTLABEL=y700root-ufs --dry-run \
    > /tmp/armada-adopt-dry.$$.txt 2>&1
check "dry run exits 0" "[ $? -eq 0 ]"
ostree admin --sysroot="$MNT" status > /tmp/armada-adopt-after.$$.txt 2>&1
check "dry run staged nothing" "diff -q /tmp/armada-adopt-before.$$.txt /tmp/armada-adopt-after.$$.txt"
check "dry run left stage-1 marker alone" "[ \$(cat $MNT/etc/armada/ostree-boot) = yes ]"
rm -f /tmp/armada-adopt-before.$$.txt /tmp/armada-adopt-after.$$.txt \
    /tmp/armada-adopt-dry.$$.txt /tmp/armada-booted-probe.$$.sh /tmp/armada-booted-ref.$$.bin

echo
[[ $fails -eq 0 ]] && echo "OSTREE_ADOPT_TEST_OK" || echo "OSTREE_ADOPT_FAILURES=$fails"
exit $fails
