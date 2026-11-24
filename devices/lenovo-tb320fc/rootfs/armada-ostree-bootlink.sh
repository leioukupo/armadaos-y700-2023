#!/bin/sh
# Ensure the deployment we booted into is visible to ostree/bootc.
#
# libostree builds its deployment list - and finds the *booted* one - from the
# bootloader specs in /boot/loader.N/entries/ostree-*.conf. Each entry carries
#   options=... ostree=/ostree/boot.<0|1>/<stateroot>/<bootcsum>/<treebootserial>
# and that path has to be a symlink whose target basename is "<csum>.<serial>".
# ostree stats the deployment behind the symlink and compares its (dev, ino)
# with the record in /run/ostree-booted; without a matching entry it fails
# outright with "bootloader entry not found", and bootc then cannot report the
# image state - which is the "Could not read OS state" the Armada tools show.
#
# Hand-made deployments (our flat-root sync commits) get no entry of their own,
# so this script writes the missing symlink and spec. It is idempotent and safe
# to run on every boot.
set -u

TAG=armada-ostree-bootlink
log() { echo "$TAG: $*"; }

bootversion=0
if [ -L /boot/loader ]; then
    case $(readlink /boot/loader) in
        loader.1) bootversion=1 ;;
        *) bootversion=0 ;;
    esac
fi
entries=/boot/loader.$bootversion/entries

# ---- which deployment? ----------------------------------------------------
# $1 may name a deployment directory; otherwise the running one, read out of the
# backing-root-device-inode (tt) pair in /run/ostree-booted: 32 bytes of key with
# its NUL and padding, then dev, then ino.
dep=${1:-}
if [ -n "$dep" ] && [ ! -d "$dep" ]; then
	log "not a deployment directory: $dep"
	exit 1
fi
if [ -z "$dep" ]; then
    ino=$(od -An -j40 -N8 -tu8 /run/ostree-booted 2>/dev/null | tr -d ' \n')
    [ -n "$ino" ] || { log "no /run/ostree-booted record, nothing to do"; exit 0; }
    for d in /ostree/deploy/*/deploy/*.*; do
        [ -d "$d" ] || continue
        [ "$(stat -c %i "$d" 2>/dev/null)" = "$ino" ] && dep=$d
    done
fi
[ -n "$dep" ] || { log "cannot find the deployment to publish"; exit 1; }
base=$(basename "$dep")
stateroot=${dep#*/ostree/deploy/}
stateroot=${stateroot%%/*}
log "deployment=$dep stateroot=$stateroot"

# ---- is it already published? ---------------------------------------------
for f in "$entries"/*.conf; do
    [ -r "$f" ] || continue
    link=$(sed -n 's/.*ostree=\([^ ]*\).*/\1/p' "$f" | head -1)
    [ -n "$link" ] || continue
    if [ "$(basename "$(readlink -f "$link" 2>/dev/null || echo none)")" = "$base" ]; then
        log "$(basename "$f") already points at it"
        exit 0
    fi
done

# ---- boot symlink farm ----------------------------------------------------
# The bootcsum is the identity ostree uses for the kernel/initrd/module content;
# reuse the one the existing farm already carries so all deployments share it.
# The stateroot directory in the farm is named "boot.<bootversion>.<subbootversion>"
# and boot.<bootversion> is a symlink to it, so glob instead of guessing the pair.
sd=
for d in /ostree/boot."$bootversion".*/"$stateroot"; do
    [ -d "$d" ] && sd=$d
done
[ -n "$sd" ] || sd=/ostree/boot."$bootversion"/"$stateroot"
bcsum=
for d in "$sd"/*/; do
    [ -d "$d" ] || continue
    bcsum=${d%/}
    bcsum=${bcsum##*/}
done
[ -n "$bcsum" ] || bcsum=${base%%.*}
farm=$sd/"$bcsum"
mkdir -p "$farm" || { log "cannot create $farm"; exit 1; }

serial=-1
for l in "$farm"/*; do
    s=${l##*/}
    [ "$s" -eq "$s" ] 2>/dev/null || continue
    [ "$s" -gt "$serial" ] && serial=$s
done
serial=$((serial + 1))
ln -s "../../../deploy/$stateroot/deploy/$base" "$farm/$serial" || {
    log "cannot link $farm/$serial"
    exit 1
}
log "bootlink $farm/$serial -> ../../../deploy/$stateroot/deploy/$base"

# ---- the bootloader spec --------------------------------------------------
kargs=
for f in "$entries"/*.conf; do
    [ -r "$f" ] || continue
    kargs=$(sed -n 's/^options //p' "$f" | head -1 | sed "s|ostree=[^ ]*||" | tr -s ' ')
    [ -n "$kargs" ] && break
done
[ -n "$kargs" ] || kargs='root=PARTLABEL=linuxroot rootwait'
kargs=$(printf '%s' "$kargs" | sed 's/ *$//')

tmpl=
for f in "$entries"/*.conf; do
    [ -r "$f" ] && grep -q '^linux ' "$f" && tmpl=$f && break
done
if [ -n "$tmpl" ]; then
    linux=$(sed -n 's/^linux //p' "$tmpl" | head -1)
    initrd=$(sed -n 's/^initrd //p' "$tmpl" | head -1)
    fdtdir=$(sed -n 's/^fdtdir //p' "$tmpl" | head -1)
else
    linux="/ostree/$stateroot-$bcsum/vmlinuz"
    initrd="/ostree/$stateroot-$bcsum/initramfs.img"
    fdtdir=
fi

version=$((serial + 1))
out=$entries/ostree-$version.conf
{
    echo "title Armada bootc-managed (ostree:$serial)"
    echo "version $version"
    echo "options $kargs ostree=/ostree/boot.$bootversion/$stateroot/$bcsum/$serial"
    [ -n "$linux" ] && echo "linux $linux"
    [ -n "$initrd" ] && echo "initrd $initrd"
    [ -n "$fdtdir" ] && echo "fdtdir $fdtdir"
} >"$out" || {
    log "cannot write $out"
    exit 1
}
log "wrote $out"
