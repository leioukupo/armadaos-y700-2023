import sys, re

P = "/tmp/y700/initramfs/init"
s = open(P).read()

# phase 1: validate every edit before touching the file
n_a34 = s.count("A34")
if n_a34 == 0:
    sys.exit("no A34 tokens in init - already bumped?")
anchor = 'banner "Y700-A35-HOLD-NO-REBOOT"'
if anchor in s:
    sys.exit("A35 block already present")
if "switch_root" in s:
    sys.exit("switch_root already in init")

s2 = s.replace("A34", "A35")
if s2.count(anchor) != 1:
    sys.exit("anchor not unique after bump: %d" % s2.count(anchor))

block = '''# ---- A35: hand the system over to the ext4 root on the SD card.
# ---- A34 proved the card itself reads in PIO mode, so the only thing left for
# ---- the initramfs is to mount the real root and switch_root into it.  Two
# ---- guards matter: (a) /init must exist and be executable in the new root,
# ---- (b) a binary from the new root must actually run.  Run the second check
# ---- through chroot() *before* switch_root, because switch_root deletes the
# ---- initramfs as its first step - an ELF the kernel refuses to execute would
# ---- leave PID 1 dead with no fallback and the board would just reboot.
RDEV="$(busybox findfs LABEL=y700root 2>/dev/null)"
P "A35 findfs rc=$? rdev=$RDEV"
if [ -z "$RDEV" ] ; then
    for d in /dev/mmcblk*p4 ; do
        [ -b "$d" ] || continue
        RDEV="$d"
        break
    done
    P "A35 fallback rdev=$RDEV"
fi
mkdir -p /mnt/root 2>/dev/null
if [ -n "$RDEV" ] && mount -t ext4 -o rw "$RDEV" /mnt/root 2>/dev/null ; then
    P "A35 root mounted dev=$RDEV top=$(ls /mnt/root | busybox tr '\\n' ' ')"
    if [ -f /mnt/root/init ] && [ -x /mnt/root/init ] ; then
        P "A35 init head=$(head -c 40 /mnt/root/init | busybox tr '\\n' ' ')"
        chroot /mnt/root /bin/busybox true 2>/dev/null
        T=$?
        P "A35 chroot-test rc=$T"
        if [ "$T" = "0" ] ; then
            busybox sync
            busybox sync
            P "A35 SWITCH_ROOT_TO $RDEV"
            exec /bin/busybox switch_root /mnt/root /init
            P "A35 SWITCH_ROOT_RETURNED rc=$?"
        else
            P "A35 CHROOT_TEST_FAILED - staying in initramfs"
        fi
    else
        P "A35 NO-ROOT-INIT"
    fi
    umount /mnt/root 2>/dev/null
    busybox sync
else
    P "A35 ROOT-MOUNT-FAILED dev=$RDEV"
fi
banner "Y700-A35-HOLD-NO-REBOOT"'''

s3 = s2.replace(anchor, block, 1)

open(P + ".bak-a35", "w").write(s)
open(P, "w").write(s3)
print("A35: init bumped %d tokens, switch_root block inserted" % n_a34)
