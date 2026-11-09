#!/usr/bin/env python3
# A82 = A81 + the initramfs is allowed to hand over to a real distribution.
#
# try_root() was written when the only root that ever existed on this board was
# the Alpine minirootfs we build ourselves: it demanded an executable /init and
# it proved the root by chroot-ing /bin/busybox and /bin/sh inside it.  The
# ArmadaOS root is a Fedora/ostree tree flattened onto sda16: it has no /init
# (its init is /sbin/init -> ../lib/systemd/systemd) and it carries no busybox,
# so the old gate rejected it and the board fell back to the card.
#
# A82 keeps every safety property and generalises the probe:
#   * accept /init, /sbin/init or /usr/lib/systemd/systemd, in that order, and
#     switch_root into whichever one exists and is executable;
#   * run the busybox chroot probe only when the candidate really ships busybox,
#     because "no busybox" is not evidence of a broken root;
#   * keep the /bin/sh exec probe (a Fedora root passes it with bash) and the
#     dev/proc/sys mountpoint gate, which is what keeps switch_root from dying
#     after it has already freed the initramfs (A37/A42 are the lessons);
#   * a new card marker CARD_FIRST_GO asks the initramfs for the SD-card root
#     without asking the card root for a UFS migration, so an install round can
#     rewrite sda16 while nothing is running on it.
import sys

P = "/tmp/y700/initramfs/init"

OLD_GATE = '''    if [ ! -f /mnt/root/init ] || [ ! -x /mnt/root/init ] ; then
        stage "A56 NO_ROOT_INIT dev=$D head=$(head -c 40 /mnt/root/init 2>/dev/null | busybox tr '\\n' ' ')"
        umount /mnt/root 2>/dev/null
        return 1
    fi
    stage "A56 init_head=$(head -c 40 /mnt/root/init | busybox tr '\\n' ' ')"
    chroot /mnt/root /bin/busybox true 2>/dev/null
    T=$?
    stage "A56 chroot_test dev=$D rc=$T"
    if [ "$T" != "0" ] ; then
        stage "A56 CHROOT_TEST_FAILED dev=$D"
        umount /mnt/root 2>/dev/null
        return 1
    fi
'''

NEW_GATE = '''    INITTGT=""
    for cand in /init /sbin/init /usr/lib/systemd/systemd ; do
        if [ -x "/mnt/root$cand" ] ; then
            INITTGT="$cand"
            break
        fi
    done
    if [ -z "$INITTGT" ] ; then
        stage "A56 NO_ROOT_INIT dev=$D head=$(head -c 40 /mnt/root/init 2>/dev/null | busybox tr '\\n' ' ') sbin=$(head -c 40 /mnt/root/sbin/init 2>/dev/null | busybox tr '\\n' ' ')"
        umount /mnt/root 2>/dev/null
        return 1
    fi
    stage "A82 root_init=$INITTGT dev=$D osrelease=$(head -c 60 /mnt/root/usr/lib/os-release 2>/dev/null | busybox tr '\\n' ' ')"
    if [ -x /mnt/root/bin/busybox ] || [ -x /mnt/root/usr/bin/busybox ] ; then
        chroot /mnt/root /bin/busybox true 2>/dev/null
        T=$?
        stage "A56 chroot_test dev=$D rc=$T"
        if [ "$T" != "0" ] ; then
            stage "A56 CHROOT_TEST_FAILED dev=$D"
            umount /mnt/root 2>/dev/null
            return 1
        fi
    else
        stage "A82 no-busybox-in-root dev=$D - busybox chroot probe skipped"
    fi
'''

OLD_MARKER = '''case "$MKT" in
    *UFS_MIGRATE_GO*) RESYNC=1 ;;
esac
'''

NEW_MARKER = '''case "$MKT" in
    *UFS_MIGRATE_GO*) RESYNC=1 ;;
    *CARD_FIRST_GO*) RESYNC=1 ;;
esac
'''

OLD_SWITCH = '''        stage "A56 SWITCH_ROOT_TO $RDEV"
        exec /bin/busybox switch_root /mnt/root /init
'''

NEW_SWITCH = '''        stage "A82 SWITCH_ROOT_TO $RDEV init=$INITTGT"
        exec /bin/busybox switch_root /mnt/root "$INITTGT"
'''

with open(P, encoding="utf-8") as h:
    src = h.read()

if "A82 SWITCH_ROOT_TO" in src:
    print("A82_PATCH_ALREADY_APPLIED")
else:
    for old in (OLD_GATE, OLD_MARKER, OLD_SWITCH):
        if src.count(old) != 1:
            print("A82_ANCHOR_COUNT", src.count(old), repr(old[:60]))
            sys.exit(1)
    src = src.replace(OLD_GATE, NEW_GATE, 1)
    src = src.replace(OLD_MARKER, NEW_MARKER, 1)
    src = src.replace(OLD_SWITCH, NEW_SWITCH, 1)
    with open(P, "w", encoding="utf-8", newline="\n") as h:
        h.write(src)
    print("A82_PATCH_APPLIED")

with open(P, encoding="utf-8") as h:
    src = h.read()
for marker in ("/usr/lib/systemd/systemd ; do",
               "no-busybox-in-root",
               "CARD_FIRST_GO*) RESYNC=1",
               'switch_root /mnt/root "$INITTGT"'):
    if marker not in src:
        print("A82_POSTCOND_MISSING " + marker)
        sys.exit(1)
print("A82_PATCH_OK")
