#!/usr/bin/env bash
# Adopt a flat Armada root into a real ostree/bootc sysroot, in place.
#
# The Gen 2 (TB320FC) image is written straight onto the UFS partition, so /usr,
# /etc and /var are plain directories: bootc/ostree are installed but there is no
# repo, no stateroot and no deployment, which is why the OS panel cannot report
# a channel, history or rollback. This stages the missing pieces from the content
# that is already running.
#
# Additive by design: the flat /usr, /etc and /var stay exactly where they are,
# so the boot_a payload that is known to boot this board keeps booting the flat
# root while the deployment waits for an ostree-aware initramfs. Undo is
# deleting what this script created (printed at the end); no boot partition is
# ever written here.
#
#   armada-ostree-adopt.sh [--sysroot DIR] [--stateroot NAME] [--ref NAME]
#                          [--dry-run] [--keep-stage] [--var link|copy|skip]
#                          [--from flat|deployment] [--version STAMP]
#                          [--root-karg KARG] [--karg KARG]... [--force]
#                          [--image-ref REF --image-meta DIR [--base-layer TAR]]
#                          [--factory-etc DIR]
#
# --image-ref writes the deployment the way bootc writes its own, which is the
# only way bootc manages it: the origin carries container-image-reference (and
# no refspec - libostree validates a refspec as an ostree branch, and putting
# the image reference there makes ostree admin status, rpm-ostree status and
# bootc status all fail to parse the deployment), while the commit carries the
# image manifest, its digest and the image configuration. Without that metadata
# bootc refuses the deployment outright ("Missing ostree.manifest-digest
# metadata on merge commit"), so there is no channel and no update target.
set -euo pipefail

SYSROOT=/
STATEROOT=default
REF=armadaos
DRY_RUN=0
KEEP_STAGE=0
VAR_MODE=link
ROOT_KARG=""
MIN_FREE_GIB=8
FORCE=0
STAGE1_MODE=install
VERSION=""
FROM_MODE=flat
IMAGE_REF=""
IMAGE_META=""
BASE_LAYER=""
# The image's factory config tree (its /usr/etc). Also readable from the environment so
# a caller that runs adopt several times does not repeat it.
FACTORY_ETC="${ARMADA_OSTREE_FACTORY_ETC:-}"
ORIGIN_FILE=""
# Transports bootc writes plus the unverified forms libostree tolerates. A tag
# is required: the digest is what an update resolves, never what a channel says.
IMAGE_REF_RE='''^(ostree-image-signed:docker://|ostree-unverified-image:docker://|ostree-unverified-registry:docker://|ostree-unverified-registry:|docker://)[A-Za-z0-9._-]+(:[0-9]{2,5})?(/[A-Za-z0-9._-]+)+:[A-Za-z0-9._-]+$'''
declare -a EXTRA_KARGS=()

die() { echo "armada-ostree-adopt: $*" >&2; exit 1; }
run() { echo "+ $*"; [[ $DRY_RUN -eq 1 ]] || "$@"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)      SYSROOT="${2:?}"; shift 2 ;;
        --sysroot=*)    SYSROOT="${1#*=}"; shift ;;
        --stateroot)    STATEROOT="${2:?}"; shift 2 ;;
        --stateroot=*)  STATEROOT="${1#*=}"; shift ;;
        --ref)          REF="${2:?}"; shift 2 ;;
        --ref=*)        REF="${1#*=}"; shift ;;
        --version)      VERSION="${2:?}"; shift 2 ;;
        --version=*)    VERSION="${1#*=}"; shift ;;
        --var)          VAR_MODE="${2:?}"; shift 2 ;;
        --var=*)        VAR_MODE="${1#*=}"; shift ;;
        --root-karg)    ROOT_KARG="${2:?}"; shift 2 ;;
        --root-karg=*)  ROOT_KARG="${1#*=}"; shift ;;
        --min-free-gib) MIN_FREE_GIB="${2:?}"; shift 2 ;;
        --min-free-gib=*) MIN_FREE_GIB="${1#*=}"; shift ;;
        --karg)         EXTRA_KARGS+=("${2:?}"); shift 2 ;;
        --karg=*)       EXTRA_KARGS+=("${1#*=}"); shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --keep-stage)   KEEP_STAGE=1; shift ;;
        --force)        FORCE=1; shift ;;
        --stage1)       STAGE1_MODE="${2:?}"; shift 2 ;;
        --stage1=*)     STAGE1_MODE="${1#*=}"; shift ;;
        --enable-stage1) STAGE1_MODE=enable; shift ;;
        --no-stage1)    STAGE1_MODE=skip; shift ;;
        --from)         FROM_MODE="${2:?}"; shift 2 ;;
        --from=*)       FROM_MODE="${1#*=}"; shift ;;
        --image-ref)    IMAGE_REF="${2:?}"; shift 2 ;;
        --image-ref=*)  IMAGE_REF="${1#*=}"; shift ;;
        --image-meta)   IMAGE_META="${2:?}"; shift 2 ;;
        --image-meta=*) IMAGE_META="${1#*=}"; shift ;;
        --base-layer)   BASE_LAYER="${2:?}"; shift 2 ;;
        --base-layer=*) BASE_LAYER="${1#*=}"; shift ;;
        --factory-etc)  FACTORY_ETC="${2:?}"; shift 2 ;;
        --factory-etc=*) FACTORY_ETC="${1#*=}"; shift ;;
        -h|--help)      sed -n '2,29p' "$0"; exit 0 ;;
        *)              die "unknown argument: $1" ;;
    esac
done

case "$VAR_MODE" in link|copy|skip) ;; *) die "--var takes link|copy|skip" ;; esac
case "$STAGE1_MODE" in install|enable|skip) ;; *) die "--stage1 takes install|enable|skip" ;; esac
case "$FROM_MODE" in flat|deployment) ;; *) die "--from takes flat|deployment" ;; esac
if [[ -n "$IMAGE_REF" ]]; then
    [[ "$IMAGE_REF" =~ $IMAGE_REF_RE ]] || \
        die "unsupported image reference: $IMAGE_REF (want ostree-unverified-image:docker://repo:tag)"
    [[ -n "$IMAGE_META" ]] || die "--image-ref needs --image-meta with manifest.json and config.json"
    [[ -f "$IMAGE_META/manifest.json" ]] || die "no $IMAGE_META/manifest.json"
    [[ -f "$IMAGE_META/config.json" ]] || die "no $IMAGE_META/config.json"
fi
SYSROOT="${SYSROOT%/}"
[[ -n "$SYSROOT" ]] || SYSROOT=/
SROOT="${SYSROOT%/}"   # "" for "/" so paths never print as "//"
STAGE="$SROOT/.ostree-stage"
cleanup_stage() {
    # A failed deploy must not leave the staging tree around; dry runs and
    # --keep-stage must not touch it either.
    [[ -n "$ORIGIN_FILE" ]] && rm -f "$ORIGIN_FILE" || true
    case "$STAGE" in */.ostree-stage) ;; *) return 0 ;; esac
    [[ $DRY_RUN -eq 1 || $KEEP_STAGE -eq 1 ]] || rm -rf "$STAGE"
    return 0
}
trap cleanup_stage EXIT
REPO="$SROOT/ostree/repo"
DEPLOY_DIR="$SROOT/ostree/deploy/$STATEROOT"
VAR_DIR="$DEPLOY_DIR/var"

[[ $EUID -eq 0 ]] || die "must run as root"
command -v ostree >/dev/null || die "ostree is not installed"
[[ -d "$SROOT/usr" ]] || die "no usr/ under sysroot $SYSROOT"
[[ -d "$SROOT/var" ]] || die "no var/ under sysroot $SYSROOT"
[[ "$VAR_MODE" != skip || $FORCE -eq 1 ]] || \
    die "--var skip needs --force: a stateroot /var with no content loses /home and /root at ostree boot"

# Never start a conversion the disk cannot hold.
free_kb=$(df -Pk "$SYSROOT" | awk 'NR==2 {print $4}')
[[ $free_kb -gt $((MIN_FREE_GIB * 1024 * 1024)) ]] || \
    die "under ${MIN_FREE_GIB} GiB free on $SYSROOT (${free_kb} KiB); a deployment needs room for the repo"

# Version stamp for the commit: the image build id, which is what the OS panel
# shows today.
if [[ -z "$VERSION" ]]; then
    VERSION=$(sed -n 's/^BUILD_ID=//p' "$SROOT/usr/lib/os-release" 2>/dev/null |
        tr -d '"' | head -1 || true)
fi
[[ -n "$VERSION" ]] || VERSION="$(date -u +%Y%m%d)-flat-adopt"

# ostree installs the kernel modules while it deploys, and it reads ID= or
# PRETTY_NAME= out of the tree's os-release to do that. Failing here is clearer
# than a half-written deployment when a root has neither field.
grep -Eq "^(ID|PRETTY_NAME)=" "$SROOT/usr/lib/os-release" 2>/dev/null || \
    die "no ID= or PRETTY_NAME= in $SROOT/usr/lib/os-release; ostree cannot install the kernel without one"

echo "sysroot=$SYSROOT stateroot=$STATEROOT ref=$REF version=$VERSION var=$VAR_MODE"

# Already converted? Re-running refreshes the commit, so say what exists.
if [[ -d "$REPO" ]]; then
    echo "existing ostree repo: $REPO"
    ostree admin --sysroot="$SYSROOT" status 2>&1 | sed -n 's/^/  /p' || true
    if [[ $FORCE -eq 0 ]] && [[ -d "$DEPLOY_DIR/deploy" ]] && \
       ls "$DEPLOY_DIR"/deploy/*.0 >/dev/null 2>&1; then
        echo "note: a deployment already exists; another will be staged from the current content."
    fi
fi

# ---- 1. sysroot skeleton + stateroot ----------------------------------------
# init-fs builds the repo and deploy skeleton, but it walks into the standard
# `ostree -> sysroot/ostree` symlink before the target exists and aborts on its
# own assertion, so the target is created first. os-init then adds the stateroot
# (var, deploy, backing).
run mkdir -p "$SROOT/sysroot"
if [[ -L "$SROOT/ostree" ]]; then
    link_target=$(readlink -f "$SROOT/ostree" 2>/dev/null || true)
    [[ -n "$link_target" ]] || die "$SROOT/ostree is a dangling symlink"
    run mkdir -p "$link_target"
elif [[ ! -e "$SROOT/ostree" ]]; then
    run mkdir -p "$SROOT/ostree"
fi
# A sysroot repo on a real ostree host is mode=bare. This board had a repo left
# behind by an aborted attempt that used the container-store default, and libostree
# refuses root writes in it: the base-layer commit died with
# "error: ostree-tar: Failed to handle file: ostree-tar: Failed to import file:
# Writing content object: Not allowed due to repo mode" after all the staging work.
# Nothing referenced those objects (no refs, no deployments), so the repo is set aside
# under a fixed name and a bare one is built in its place.
MOVED_REPO=""
if [[ -f "$REPO/config" ]]; then
    repo_mode=$(ostree --repo="$REPO" config get core.mode 2>/dev/null || echo unknown)
    if [[ "$repo_mode" != bare ]]; then
        echo "note: $REPO is core.mode=$repo_mode; an ostree host sysroot needs bare"
        if [[ $DRY_RUN -eq 0 ]]; then
            [[ ! -e "$REPO.pre-adopt" ]] || die "$REPO.pre-adopt already exists: clear it or adopt --force is not enough here"
            run mv "$REPO" "$REPO.pre-adopt"
            [[ $DRY_RUN -eq 1 ]] || MOVED_REPO="$REPO.pre-adopt"
            run ostree init --repo="$REPO" --mode=bare
            echo "note: rebuilt $REPO as mode=bare; the old one is kept at $REPO.pre-adopt"
        fi
    fi
fi
if [[ ! -f "$REPO/config" ]]; then
    run ostree admin init-fs "$SYSROOT" || \
        echo "note: init-fs did not finish; building the skeleton directly"
    if [[ $DRY_RUN -eq 0 && ! -f "$REPO/config" ]]; then
        run mkdir -p "$REPO" "$DEPLOY_DIR/var" "$DEPLOY_DIR/deploy" "$DEPLOY_DIR/backing"
        run ostree init --repo="$REPO"
    fi
fi
# The deploy skeleton has to exist before libostree will look at the sysroot at all.
# HA1WZJJ5 met exactly this: the aborted first attempt left /ostree/repo behind (config
# plus 2.1 GB of objects) with no ostree/deploy, and libostree 2026.4 then answers
# "error: loading sysroot: fstatat(ostree/deploy): No such file or directory" for
# `ostree admin status` *and* for `ostree admin os-init`, so os-init cannot be the call
# that creates the tree it insists on having. Make the skeleton, then let os-init add
# the stateroot; if that still fails, build the stateroot the same way the fresh-repo
# path above does.
run mkdir -p "$SROOT/ostree/deploy"
if [[ ! -d "$DEPLOY_DIR" ]]; then
    run ostree admin --sysroot="$SYSROOT" os-init "$STATEROOT" || \
        echo "note: os-init did not finish; building the stateroot directly"
    if [[ $DRY_RUN -eq 0 && ! -d "$DEPLOY_DIR" ]]; then
        run mkdir -p "$DEPLOY_DIR/var" "$DEPLOY_DIR/deploy" "$DEPLOY_DIR/backing"
    fi
fi
run mkdir -p "$DEPLOY_DIR/var" "$DEPLOY_DIR/deploy"
[[ $DRY_RUN -eq 1 || -f "$REPO/config" ]] || die "no ostree repo at $REPO"
[[ $DRY_RUN -eq 1 || -d "$DEPLOY_DIR" ]] || die "no stateroot at $DEPLOY_DIR"

# ---- 2a. which tree becomes the commit -------------------------------------
# A board that already boots a deployment keeps its drift (installed files in
# /usr, everything the machine changed since the adopt) in that checkout, while
# the flat root under $SROOT still holds the pre-adopt content. Re-adopting has
# to commit what is actually running, not what the installer wrote.
SRC_ROOT="$SROOT"
if [[ "$FROM_MODE" == deployment ]]; then
    src_dep=; src_dep_serial=-1
    for d in "$DEPLOY_DIR"/deploy/*; do
        [[ -d "$d" ]] || continue
        s=${d##*.}
        [[ $s =~ ^[0-9]+$ ]] || continue
        if (( s >= src_dep_serial )); then src_dep_serial=$s; src_dep=$d; fi
    done
    [[ -n "$src_dep" ]] || die "--from deployment: no deployment under $DEPLOY_DIR/deploy"
    SRC_ROOT="$src_dep"
    # Hard links need both ends on one mount. The deployment checkout is reached
    # through $SROOT/ostree, and $SROOT itself is a second mount of the same
    # partition, so the staging tree moves to the deployment side of that.
    STAGE="$SROOT/ostree/deploy/.ostree-stage"
fi
echo "commit tree: $SRC_ROOT"

# libostree refuses to create a deployment from a tree with no kernel in it:
# `ostree admin deploy` ends with "Failed to find kernel in /usr/lib/modules,
# /usr/lib/ostree-boot or /boot". That is not a corner case on this board - the payload
# kernel is written out of band into the raw boot partition, and a kernel package built
# from modules only leaves /usr/lib/modules/<kver> without a vmlinuz, so the whole
# adoption (14 GB of staging and committing on HA1WZJJ5) finished before it failed.
# Ask the same question first, and say what answers it.
have_kernel=0
for cand in "$SRC_ROOT"/usr/lib/modules/*/vmlinuz \
            "$SRC_ROOT"/usr/lib/ostree-boot/vmlinuz* \
            "$SRC_ROOT"/boot/vmlinuz-*; do
    [[ -f "$cand" ]] && { have_kernel=1; break; }
done
[[ $have_kernel -eq 1 ]] || die "no kernel in $SRC_ROOT/usr/lib/modules/*/vmlinuz: ostree cannot deploy this tree. Put the payload Image there (packages/kernel/scripts/build-kernel.sh stages arch/arm64/boot/Image at lib/modules/<kver>/vmlinuz); for a board that is already running, the same bytes come out of the boot partition at the kernel section of its boot_<slot> image."

# ---- 2b. stage the commit tree (never the live /etc or /var) ---------------
# ostree refuses a tree holding both /etc and /usr/etc, and the live /etc is the
# machine's own state, so only /usr/etc goes into the commit. /var belongs to
# the stateroot, not the deployment: the tree gets the mount-point skeleton that
# /home, /root, /srv and /mnt symlink into.
run rm -rf "$STAGE"
run mkdir -p "$STAGE"
# Anything mounted from another filesystem is runtime state, not part of the
# tree: on this board the Android guest images ride in as loop mounts under
# /usr/share/guestos, and hard links cannot cross a filesystem anyway.
src_mnt=$(stat -c %m "$SRC_ROOT" 2>/dev/null || echo /)
foreign=$(findmnt -n -r -o TARGET,FSTYPE 2>/dev/null | awk -v s="${src_mnt%/}/" \
  '$1 ~ "^" s && $1 !~ "^" s "(proc|sys|dev|run|tmp|mnt|media|sysroot|boot/efi)($|/)" { print "  " $0 }' \
  || true)
if [[ -n "$foreign" ]]; then
    echo "not staged, separate filesystems:"
    printf '%s\n' "$foreign"
fi

declare -a STAGED=()
# init is the stage-1 launcher installed by this script, not tree content: a
# deployment must never carry a second hook that re-arms the root switch.
# armada-ostree is stage-1 runtime state (attempt/confirmed/failed/boot.log). It
# belongs to the physical root only: committing it would churn the tree on every boot.
SKIP=' etc var init boot ostree sysroot armada-ostree proc sys dev run tmp mnt media lost+found '
shopt -s dotglob nullglob
for path in "$SRC_ROOT"/*; do
    name=${path##*/}
    # Root dotfiles are installer leftovers or this script's own staging area
    # (.ostree.cfs, .autorelabel, .ostree-stage); none of them belong in a tree.
    if [[ "$name" == .* ]]; then continue; fi
    case "$SKIP" in *" $name "*) continue ;; esac
    if ! run cp -alx "$path" "$STAGE/"; then
        [[ $DRY_RUN -eq 1 ]] && continue
        # Hard links cannot cross the bind mounts this board composes its root
        # from; a copy costs a little space and gives the same tree.
        echo "note: $path is not hard-linkable, copying it"
        run rm -rf "$STAGE/$name"
        run cp -ax "$path" "$STAGE/" || die "cannot stage $path"
    fi
    STAGED+=("$name")
done
shopt -u dotglob nullglob
for skeleton in home roothome srv mnt opt tmp; do
    run mkdir -p "$STAGE/var/$skeleton"
done
run chmod 1777 "$STAGE/var/tmp"
# The mount points that a root switch moves mounts onto, plus the standard
# `ostree -> sysroot/ostree` link, have to ride in the commit. Measured on
# libostree 2024.5 and on the board's 2026.x: `ostree admin deploy` creates
# none of them inside the deployment, and it leaves the deployment directory
# immutable (`----i----`), so nothing can be created there later either - not
# at boot, not by the adopt script. boot is the boot partition on a normal ostree
# host, so it stays a mount point here too: the payload ostree writes into /boot
# must not become tree content, or every deploy would commit the previous one.
# The commit tree has to carry /usr/etc. A flat install keeps its config at /etc and has
# nothing at /usr/etc, and libostree only notices at the end of the second deployment:
# "Deploying tree: Finalizing deployment: During /etc merge: While computing
# configuration diff: Error when getting information for file /proc/self/fd/14/usr/etc:
# No such file or directory" on HA1WZJJ5 - the first adopt, with no previous deployment
# to diff against, had gone through. The live /etc must not be copied into the tree
# (machine state stays out of the commit, A185), so the factory config is brought in
# from the image it belongs to: --factory-etc DIR, where DIR is that image's /usr/etc.
if [[ ! -d "$STAGE/usr/etc" ]]; then
    if [[ -n "$FACTORY_ETC" ]]; then
        [[ -d "$FACTORY_ETC" ]] || die "--factory-etc: no such directory $FACTORY_ETC"
        run mkdir -p "$STAGE/usr/etc"
        if ! run cp -alx "$FACTORY_ETC/." "$STAGE/usr/etc/"; then
            # Not the same filesystem, or a bind mount in the way: a copy costs a few
            # tens of MB and gives the same tree. (--dry-run never really runs the cp
            # above, so there is nothing to repair in that case.)
            if [[ $DRY_RUN -eq 0 ]]; then
                echo "note: $FACTORY_ETC is not hard-linkable here, copying it"
                run rm -rf "$STAGE/usr/etc"
                run mkdir -p "$STAGE/usr/etc"
                run cp -ax "$FACTORY_ETC/." "$STAGE/usr/etc/"
            fi
        fi
        n_etc=$(find "$FACTORY_ETC" -maxdepth 1 ! -path "$FACTORY_ETC" 2>/dev/null | wc -l || true)
        echo "factory /usr/etc staged from $FACTORY_ETC (top-level=$n_etc)"
    else
        run mkdir -p "$STAGE/usr/etc"
        echo "note: the flat root has no /usr/etc and --factory-etc was not given."
        echo "      the tree gets an empty /usr/etc so libostree can still merge /etc, but"
        echo "      every config file will read as a local change on the next deployment."
    fi
fi
for skeleton in sysroot run dev proc sys tmp boot; do
    run mkdir -p "$STAGE/$skeleton"
done
run chmod 1777 "$STAGE/tmp"
run ln -sfn sysroot/ostree "$STAGE/ostree"
echo "staged: ${STAGED[*]}"
[[ ${#STAGED[@]} -gt 0 ]] || die "nothing to commit under $SYSROOT"

# ---- 3. stateroot /var ------------------------------------------------------
# The deployment bind-mounts this over /var, so it has to hold the machine's
# data before any ostree boot. Hard links keep one copy of the data on disk and
# keep the flat root and the deployment looking at the same inodes; --no-clobber
# makes a re-run leave already-diverged copies alone.
if [[ "$VAR_MODE" != skip ]]; then
    seeded=0
    if [[ -z "$(find "$VAR_DIR" -mindepth 1 ! -name '.ostree-selabeled' -print -quit 2>/dev/null)" ]]; then
        run mkdir -p "$VAR_DIR"
        cp_flag=-l
        if [[ "$VAR_MODE" == copy ]]; then cp_flag=-a; fi
        # Hard links only exist inside one filesystem, and they do not even
        # cross a bind mount of that filesystem - the board answers EXDEV for
        # those. st_dev cannot spot the difference, because two mounts of one
        # filesystem report the same st_dev, so compare mount points instead.
        if [[ "$cp_flag" == -l ]]; then
            src_mnt=$(stat -c %m "$SROOT/var" 2>/dev/null || echo unknown)
            dst_mnt=$(stat -c %m "$DEPLOY_DIR" 2>/dev/null || echo unknown)
            if [[ "$src_mnt" != "$dst_mnt" ]]; then
                echo "note: $SROOT/var sits on $src_mnt but $DEPLOY_DIR on $dst_mnt; seeding with a copy instead of hard links"
                cp_flag=-a
            fi
        fi
        run cp "$cp_flag" -an --one-file-system "$SROOT/var/." "$VAR_DIR/"
        seeded=1
    fi
    # A tree that stopped halfway through seeding still reads as non-empty
    # above, so report the counts instead of trusting non-emptiness.
    # || true: with --dry-run the seeding above never ran, so $VAR_DIR does not
    # exist yet, and a counting find must not end the run under pipefail. The
    # first ever dry run on a fresh board died exactly here, with no message.
    n_src=$(find "$SROOT/var" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l || true)
    n_dst=$(find "$VAR_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l || true)
    if [[ $seeded -eq 0 && $n_dst -lt $n_src ]]; then
        echo "warning: $VAR_DIR holds $n_dst of $n_src top-level entries of $SROOT/var; half-seeded - delete it and re-run to seed again"
    fi
    # selinux=0 on this board: a relabel walk of a multi-gigabyte /var is noise.
    if grep -q 'selinux=0' /proc/cmdline 2>/dev/null; then
        run touch "$VAR_DIR/.ostree-selabeled"
    fi
    if [[ $seeded -eq 1 ]]; then
        echo "stateroot var: seeded at $VAR_DIR (src=$n_src dst=$n_dst)"
    else
        echo "stateroot var: kept at $VAR_DIR (src=$n_src dst=$n_dst)"
    fi
fi

# ---- 3a. image identity ----------------------------------------------------
# What bootc reads as a deployment's image is commit metadata: the manifest,
# its digest and the image configuration (ostree-ext META_MANIFEST,
# META_MANIFEST_DIGEST and META_CONFIG). The first manifest layer also has to
# resolve to a commit in this repo - that is how query_image_commit separates
# the base image from the local tree - so the base layer is imported under the
# blob ref ostree-ext names layers by.
declare -a COMMIT_IMAGE_ARGS=()
declare -a ORIGIN_ARG=()
IMAGE_BLOB_REF=; IMAGE_STORE_REF=; IMAGE_MANIFEST_DIGEST=
if [[ -n "$IMAGE_REF" ]]; then
    image_info=$(python3 - "$IMAGE_META" "$IMAGE_REF" "${BASE_LAYER:-}" <<'PY'
import hashlib
import json
import shlex
import sys

meta, ref, base_layer = sys.argv[1], sys.argv[2], sys.argv[3]
manifest = open(meta + "/manifest.json", "rb").read()
config = open(meta + "/config.json", encoding="utf-8").read().strip()
data = json.loads(manifest)
parsed_config = json.loads(config)
layers = data.get("layers") or []
first = layers[0].get("digest") if layers else None
if not isinstance(first, str) or not first.startswith("sha256:"):
    raise SystemExit("manifest.json has no sha256 first-layer digest")
if "config" not in parsed_config and "configuration" not in parsed_config:
    raise SystemExit("config.json is not an image configuration")
if base_layer:
    digest = "sha256:" + hashlib.sha256(open(base_layer, "rb").read()).hexdigest()
    if digest != first:
        raise SystemExit(base_layer + " is not this manifest's base layer (" + first + ")")


def escape(value):
    # ostree-ext refescape::escape_for_ref: alphanumerics and - pass through,
    # _ quotes itself, / passes between alphanumerics, everything else is _XX_.
    out, previous, chars = [], False, list(value)
    for i, c in enumerate(chars):
        alnum = c.isascii() and c.isalnum()
        if alnum:
            out.append(c)
        elif c == "/" and previous and i + 1 < len(chars):
            out.append(c)
        elif c == "-":
            out.append(c)
        elif c == "_":
            out.append("__")
        else:
            out.append("_%02X_" % ord(c))
        previous = alnum
    return "".join(out)


inner = ref
for prefix in ("ostree-image-signed:docker://", "ostree-unverified-image:docker://",
               "ostree-unverified-registry:docker://", "ostree-unverified-registry:",
               "docker://"):
    if inner.startswith(prefix):
        inner = inner[len(prefix):]
        break
if "://" not in inner:
    inner = "docker://" + inner

for name, value in (("IMAGE_MANIFEST_DIGEST", "sha256:" + hashlib.sha256(manifest).hexdigest()),
                    ("IMAGE_BLOB_REF", "ostree/container/blob/" + escape(first)),
                    ("IMAGE_STORE_REF", "ostree/container/image/" + escape(inner))):
    print("%s=%s" % (name, shlex.quote(value)))
PY
) || die "cannot read the image metadata from $IMAGE_META"
    eval "$image_info"
    echo "image: $IMAGE_REF manifest $IMAGE_MANIFEST_DIGEST"
    COMMIT_IMAGE_ARGS=(
        --add-metadata-string="ostree.manifest-digest=$IMAGE_MANIFEST_DIGEST"
        --add-metadata-string="ostree.manifest=$(< "$IMAGE_META/manifest.json")"
        --add-metadata-string="ostree.container.image-config=$(< "$IMAGE_META/config.json")"
    )
    if ! ostree --repo="$REPO" rev-parse "$IMAGE_BLOB_REF" >/dev/null 2>&1; then
        [[ -n "$BASE_LAYER" && -f "$BASE_LAYER" ]] || \
            die "the base layer of $IMAGE_REF is not in this repo; --base-layer needs its tar ($IMAGE_BLOB_REF)"
        run ostree --repo="$REPO" commit -b "$IMAGE_BLOB_REF" --tar-autocreate-parents --tree=tar="$BASE_LAYER"
    fi
    # A root that was composed by stage-1 carries the ext4 immutable bit on its
    # top-level directory, so creating a file under the sysroot root fails with
    # EPERM there. libostree reads --origin-file from any path, so stage the
    # origin outside the sysroot - a flat root and a composed one both accept
    # that - and let the exit trap remove it.
    ORIGIN_FILE=$(mktemp "${TMPDIR:-/tmp}/armada-ostree-origin.XXXXXX") || \
        die "cannot write a temporary origin file"
    printf '[origin]\ncontainer-image-reference=%s\n' "$IMAGE_REF" > "$ORIGIN_FILE"
    ORIGIN_ARG=(--origin-file="$ORIGIN_FILE")
fi

# ---- 4. commit --------------------------------------------------------------
commit_cmd=(ostree --repo="$REPO" commit
    -b "$REF"
    --add-metadata-string="version=$VERSION"
    --add-metadata-string="armada.adopt.from=flat-root"
    --add-metadata-string="armada.adopt.stateroot=$STATEROOT"
    --add-metadata-string="armada.adopt.host=$(hostname 2>/dev/null || echo unknown)"
    --add-metadata-string="armada.adopt.tree=$SRC_ROOT"
    "${COMMIT_IMAGE_ARGS[@]}"
    --tree=dir="$STAGE")
if [[ $DRY_RUN -eq 1 ]]; then
    # The dry run prints the command it would run, image metadata included:
    # that metadata is the whole reason bootc takes the deployment over.
    echo "+ ${commit_cmd[*]}"
    commit="(dry run)"
else
commit=$("${commit_cmd[@]}")
echo "commit: $commit"
fi

# ---- 5. deployment + kernel arguments ---------------------------------------
# root= comes from the running partition so the staged entry cannot point at a
# different disk than the one that holds it.
if [[ -z "$ROOT_KARG" ]]; then
    root_dev=$(findmnt -no SOURCE -T "$SYSROOT" 2>/dev/null || true)
    if [[ -n "$root_dev" && -b "$root_dev" ]]; then
        label=$(blkid -s PARTLABEL -o value "$root_dev" 2>/dev/null || true)
        uuid=$(blkid -s PARTUUID -o value "$root_dev" 2>/dev/null || true)
        if [[ -n "$label" ]]; then ROOT_KARG="root=PARTLABEL=$label";
        elif [[ -n "$uuid" ]]; then ROOT_KARG="root=PARTUUID=$uuid"; fi
    fi
fi
[[ -n "$ROOT_KARG" || $FORCE -eq 1 ]] || \
    die "cannot derive root= for $SYSROOT (use --root-karg, or --force to stage none)"

declare -a KARGS=()
if [[ -n "$ROOT_KARG" ]]; then KARGS+=("--karg=$ROOT_KARG"); fi
# The board tuning the known-good boot payload carries; without it this SoC does
# not bring up display/clocks, so the deployment entry has to keep it.
for karg in rootwait selinux=0 systemd.unit=multi-user.target console=tty0 \
            iomem=relaxed nokaslr loglevel=4 consoleblank=0 clk_ignore_unused \
            pd_ignore_unused no_console_suspend panic=0 softlockup_panic=1 \
            watchdog_thresh=4 hung_task_panic=1 deferred_probe_timeout=0 \
            y700_pause=0 \
            initcall_blacklist=clk_disable_unused,genpd_power_off_unused,regulator_init_complete; do
    KARGS+=("--karg=$karg")
done
for karg in "${EXTRA_KARGS[@]}"; do KARGS+=("--karg=$karg"); done


# ---- 5a. leftover composition mounts ---------------------------------------
# A composed boot binds the deployment tree on ostree/.stage1-root, hangs the
# physical root under its sysroot and the stateroot var under its var, mounts a
# tmpfs on its run, then pivots into it. A boot that pivots cleans up after
# itself; a composition that is interrupted, or one run in the same session as a
# re-adoption, leaves those mounts behind. Deploying prunes superseded
# deployments, and pruning a tree that still carries a mount fails the whole
# deploy with EBUSY - on a board with no TF card and no serial console that is an
# adoption that can be neither finished nor repeated.
#
# Two things make this dangerous, and both are handled:
#  - the sysroot bind copies the running system's whole mount subtree, so copies
#    of proc/sys/dev sit below the composition and share a propagation group with
#    the real ones. Making the subtree rprivate first is what lets the copies go
#    away without taking the live mounts with them.
#  - when the system is *running* from that composition, those paths resolve to
#    the live /proc, /sys and /run, so nothing here may be unmounted at all. A
#    composition tree bind-mounted as / has the inode of /, which is how it is
#    recognised.
if [[ $DRY_RUN -eq 0 ]]; then
    live_root=$(stat -c '%d:%i' / 2>/dev/null || echo none)
    for runtime in "$SROOT/ostree/.stage1-root" "$SROOT/sysroot/ostree/.stage1-root"; do
        [[ -d "$runtime" ]] || continue
        if [[ "$(stat -c '%d:%i' "$runtime" 2>/dev/null)" == "$live_root" ]]; then
            echo "note: this system is running the composition at $runtime; its mounts stay"
            continue
        fi
        # A leftover .stage1-root is often just the directory stage-1 made, not
        # a mount any more, and failing to make it private is not a reason to
        # give up on the adoption that follows it.
        mount --make-rprivate "$runtime" 2>/dev/null || true
        # The awk rule has to keep its condition and its action on one line: an
        # action written on the line after a complete condition is a second rule
        # that matches every mount, and this loop unmounts what it matches. The
        # shell-side check is the same rule spelled twice, because getting this
        # filter wrong costs more than a mount.
        while IFS= read -r target; do
            [[ "$target" == "$runtime" || "$target" == "$runtime"/* ]] || continue
            if umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null; then
                echo "note: unmounted the leftover composition mount $target"
            else
                echo "warning: $target is still mounted"
            fi
        done < <(awk -v mp="$runtime" '$5 == mp || index($5, mp "/") == 1 { print $5 }' \
            /proc/self/mountinfo 2>/dev/null | sort -r)
    done
    # A mount attached straight to a deployment tree mount point is the other way
    # a stale composition shows up, and stat does see it through st_dev. The tree
    # this system runs from is skipped for the same reason as above.
    for dep in "$DEPLOY_DIR"/deploy/*; do
        [[ -d "$dep" ]] || continue
        [[ "$(stat -c '%d:%i' "$dep" 2>/dev/null)" == "$live_root" ]] && continue
        dep_fs=$(stat -c %d "$dep" 2>/dev/null)
        for mp in run dev proc sys tmp; do
            [[ -d "$dep/$mp" ]] || continue
            [[ "$(stat -c %d "$dep/$mp" 2>/dev/null)" != "$dep_fs" ]] || continue
            echo "note: unmounting stale $dep/$mp"
            umount -l "$dep/$mp" 2>/dev/null || echo "warning: $dep/$mp is still busy"
        done
    done
fi

deploy_cmd=(ostree admin --sysroot="$SYSROOT" deploy --os="$STATEROOT"
    "${KARGS[@]}" "${ORIGIN_ARG[@]}" "$REF")
if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ ${deploy_cmd[*]}"
else
    # ostree writes the new deployment first and prunes the superseded ones at the
    # end of the transaction. A prune that cannot finish makes the command exit
    # non-zero even though the new deployment is on disk, and treating that as a
    # failed adoption would throw away the work that did succeed: a stale old
    # deployment costs disk space, a half-retried adoption risks more than that.
    deploy_out=$(mktemp "${TMPDIR:-/tmp}/armada-ostree-deploy.XXXXXX")
    deploy_failed=0
    if ! "${deploy_cmd[@]}" >"$deploy_out" 2>&1; then deploy_failed=1; fi
    sed -n 's/^/  /p' "$deploy_out"
    if [[ $deploy_failed -eq 1 ]] && ! grep -q 'Cleaning deployments' "$deploy_out"; then
        rm -f "$deploy_out"
        die "ostree admin deploy failed"
    fi
    if [[ $deploy_failed -eq 1 ]]; then
        rm -f "$deploy_out"
        [[ -d "$DEPLOY_DIR/deploy/$commit.0" ]] || die "deploy left no deployment for $commit"
        echo "warning: a superseded deployment could not be pruned; ostree admin undeploy <serial> removes it"
    else
        rm -f "$deploy_out"
    fi
fi

if [[ -n "$IMAGE_REF" && $DRY_RUN -eq 0 ]]; then
    # ostree-ext keeps a ref under ostree/container/image for every image a repo
    # holds. Writing it here is what keeps the layer refs alive under garbage
    # collection, and it is what lets "ostree container image list" see this one.
    # The ref names the merge commit of this run, so a second adoption has to move it
    # rather than stop: ostree refs --create refuses an existing name outright
    # ("--create specified but ref ostree/container/image/... already exists"), which is
    # where attempt 6 on HA1WZJJ5 died - after "Bootloader updated; bootversion: boot.1.1,
    # deployment count change: 1" had already written the deployment it came for.
    if ostree --repo="$REPO" rev-parse "$IMAGE_STORE_REF" >/dev/null 2>&1; then
        echo "note: replacing the existing $IMAGE_STORE_REF ref"
        run ostree --repo="$REPO" refs --delete "$IMAGE_STORE_REF"
    fi
    run ostree --repo="$REPO" refs --create="$IMAGE_STORE_REF" "$commit"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "dry run: nothing was written under $SYSROOT"
    run rm -rf "$STAGE"
    exit 0
fi

# ---- 5a. the composed-boot confirmation unit -------------------------------
here=$(cd -- "$(dirname -- "$0")" && pwd)
# stage-1 records an attempt before it moves any mount, and this unit is what
# tells the next boot the composed root really came up. Without it a composition
# that dies before systemd would be retried forever, which on a board with no TF
# card and no console has no way back. It lives in /etc because /etc is machine
# state, and the deployment /etc seeding below carries it into the deployment.
unit=armada-ostree-confirm.service
if [[ "$STAGE1_MODE" != skip ]]; then
    [[ -f "$here/$unit" ]] || die "missing $unit next to $0"
    run mkdir -p "$SROOT/etc/systemd/system"
    run install -m 0644 "$here/$unit" "$SROOT/etc/systemd/system/$unit"
    # WantedBy=basic.target, and that is the point: the unit is After=basic.target
    # so a composed boot that stalls on some later unit still confirms itself. A
    # wants link under multi-user.target would only be pulled in once multi-user
    # was reached - the exact shape that made the first version report a healthy
    # desktop as a dead boot (PROGRESS A196).
    run mkdir -p "$SROOT/etc/systemd/system/basic.target.wants"
    run ln -sf "../$unit" "$SROOT/etc/systemd/system/basic.target.wants/$unit"
    echo "confirm unit: $SROOT/etc/systemd/system/$unit enabled"
fi

# ---- 5b. seed the deployment /etc -----------------------------------------
# /etc is machine state, and with no previous deployment libostree fills the new
# /etc from /usr/etc only. A first boot of that deployment would come up with no
# machine-id, no passwd and no fstab, so seed it from the live /etc; the tree's
# own /usr/etc files already landed there and win the no-clobber race.
# Highest deploy serial, the way armada-ostree-stage1.sh picks it. Note the -d:
# without it ls lists the contents of the deployment directory.
newest=
newest_serial=-1
for d in "$DEPLOY_DIR"/deploy/*; do
    [[ -d "$d" ]] || continue
    s=${d##*.}
    [[ $s =~ ^[0-9]+$ ]] || continue
    if (( s >= newest_serial )); then
        newest_serial=$s
        newest=$d
    fi
done
if [[ "$FROM_MODE" == deployment ]]; then
    # The new deployment merges /etc from the running one, and $SROOT/etc is
    # that running /etc right now; seeding it again would only churn links.
    echo "deployment /etc: merged from the running deployment"
elif [[ -n "$newest" && -d "$newest/etc" ]]; then
    run cp -alxn "$SROOT/etc/." "$newest/etc/"
    echo "seeded deployment /etc from $SROOT/etc into $newest/etc"
else
    echo "note: no deployment /etc to seed under $DEPLOY_DIR"
fi

# ---- 5c. the stage-1 root switch -------------------------------------------
# Booting the deployment does not need a new boot payload on this board: the
# initramfs in boot_a picks the root's init from /init, /sbin/init,
# /usr/lib/systemd/systemd in that order, so an /init that composes the
# deployment and then execs systemd is enough - and it falls back to the plain
# systemd boot when anything is missing. The files are installed, but the
# marker stays off unless --enable-stage1 says otherwise.
if [[ "$STAGE1_MODE" != skip ]]; then
    # The confirm unit ExecStarts armada-ostree-confirm.sh, so installing only
    # stage1.sh can never confirm a boot: stage-1 counts that as a dead attempt
    # and after two of them the kill switch turns the composed root off.
    # Both trees need them, not only the physical root: a composed boot runs the
    # stage-1 files out of the *deployment* (/usr comes from the commit), and an
    # 0644 copy in there makes confirm die on "Permission denied" - which stage-1
    # then counts as a dead composed boot. $newest is the deployment this run just
    # built; editing it after checkout is an overlay ostree never verifies, and the
    # next adopt/checkpoint rewrites it from the flat root anyway.
    # A list, not a string: --sysroot / leaves SROOT empty on purpose (so paths never
    # print as //), and a space-joined list loses that empty element to word splitting.
    # On HA1WZJJ5 that meant the physical root was skipped entirely - no /init, no
    # stage-1 runtime - while every per-root check still passed because they only ever
    # saw the deployment.
    roots=("$SROOT")
    [[ -n "${newest:-}" && -d "$newest" ]] && roots+=("$newest")
    for root in "${roots[@]}"; do        # libostree marks a deployment's top-level directory immutable (the same
        # reason `ostree admin unlock` exists), so creating /init inside the tree
        # this run just checked out fails with EPERM: install aborts, adopt exits
        # non-zero and the marker never appears. Drop the flag for the duration of
        # the install and put it back, which is how libostree leaves it.
        imm=0
        if [[ "$root" != "$SROOT" ]] && lsattr -d "$root" 2>/dev/null | awk '{print $1}' | grep -q i; then
            run chattr -i "$root" && imm=1
        fi
        for name in armada-ostree-stage1.sh armada-ostree-confirm.sh armada-ostree-bootlink.sh; do
            src="$here/$name"; dst="$root/usr/lib/armada/$name"
            [[ -f "$src" ]] || die "missing $name next to $0"
            if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
                echo "note: $dst already current"
            else
                run install -m 0755 "$src" "$dst"
            fi
            run chmod 0755 "$dst"
        done
        # /init belongs to the physical root only: the boot_a initramfs picks it from
        # the mounted linuxroot before anything is composed, so a copy inside a
        # deployment tree is never executed - it would only leave a launcher in a
        # tree ostree verifies, and a later checkout would not carry it.
        if [[ "$root" == "$SROOT" ]]; then
            src="$here/init-ostree"; dst="$root/init"
            [[ -f "$src" ]] || die "missing init-ostree next to $0"
            if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
                echo "note: $dst already current"
            else
                run install -m 0755 "$src" "$dst"
            fi
            run chmod 0755 "$dst"
        fi
        [[ $imm -eq 1 ]] && run chattr +i "$root"
    done
    # The confirm ExecStart is a file in /usr/lib/armada, and the unit itself may
    # live in /etc/systemd/system (which is shared with the physical root). Install
    # the unit where the deployment cannot hide it, then prove every piece is
    # executable before anyone is told the composed root is available.
    for root in "${roots[@]}"; do
        unit="$root/usr/lib/systemd/system/armada-ostree-confirm.service"
        [[ -f "$here/armada-ostree-confirm.service" ]] || die "missing armada-ostree-confirm.service next to $0"
        # Not every root has a /usr/lib/systemd/system yet (a fresh adopt on a flat
        # tree, or a unit-less fixture); install would fail on the missing parent.
        run mkdir -p "$(dirname "$unit")"
        run install -m 0644 "$here/armada-ostree-confirm.service" "$unit"
    done
    for root in "${roots[@]}"; do
        files=("$root/usr/lib/armada/armada-ostree-stage1.sh" \
               "$root/usr/lib/armada/armada-ostree-confirm.sh" \
               "$root/usr/lib/armada/armada-ostree-bootlink.sh")
        [[ "$root" == "$SROOT" ]] && files=("$root/init" "${files[@]}")
        for f in "${files[@]}"; do
            [[ -x "$f" ]] || die "stage-1 file is not executable: $f"
        done
    done
    shown=()
    for root in "${roots[@]}"; do
        [[ -n "$root" ]] && shown+=("$root") || shown+=("/")
    done
    echo "stage-1 files installed and verified executable in:${shown[*]}"
    # And say the two things that actually gate the boot, by name, instead of trusting
    # the list that produced them: the payload initramfs picks the root's init from
    # /init, and /init is only a launcher if the stage-1 runtime is beside it.
    if [[ $DRY_RUN -eq 0 ]]; then
        [[ -x "${SROOT}/init" ]] || \
            die "stage-1 installed but ${SROOT}/init is missing or not executable"
        [[ -x "${SROOT}/usr/lib/armada/armada-ostree-stage1.sh" ]] || \
            die "stage-1 installed but ${SROOT}/usr/lib/armada/armada-ostree-stage1.sh is missing or not executable"
    fi
    marker="$SROOT/etc/armada/ostree-boot"
    if [[ -e "$marker" ]]; then
        echo "note: keeping existing $marker ($(cat "$marker" 2>/dev/null))"
    else
        run mkdir -p "$SROOT/etc/armada"
        value=no
        [[ "$STAGE1_MODE" == enable ]] && value=yes
        run sh -c "printf '%s\n' $value > '$marker'"
    fi
    echo "stage-1: $STAGE1_MODE (marker $marker turns the composed root on)"
fi

# ---- 6. what landed ---------------------------------------------------------
echo "== ostree admin status"
ostree admin --sysroot="$SYSROOT" status 2>&1 | sed -n 's/^/  /p' || true
if [[ -n "$IMAGE_REF" ]]; then
    echo "== origin files"
    for o in "$DEPLOY_DIR"/deploy/*.origin; do
        [[ -f "$o" ]] || continue
        echo "  $o"
        sed -n 's/^/    /p' "$o"
    done
    echo "== refs"
    ostree --repo="$REPO" refs 2>&1 | sed -n 's/^/  /p' || true
    if [[ "$SYSROOT" == / && $DRY_RUN -eq 0 ]] && command -v bootc >/dev/null; then
        echo "== bootc status"
        bootc status 2>&1 | sed -n '1,24p' | sed -n 's/^/  /p' || true
    fi
fi

entry=$(ls -1t "$SYSROOT"/boot/loader*/entries/*.conf 2>/dev/null | head -1 || true)
if [[ -n "$entry" ]]; then
    options=$(sed -n 's/^options //p' "$entry" | head -1)
    ostree_karg=$(printf '%s\n' "$options" | tr ' ' '\n' | grep '^ostree=' || true)
    echo "== BLS $entry"
    printf '  %s\n' "$options"
    [[ -n "$ostree_karg" ]] || die "BLS entry has no ostree= karg: $entry"
    # ABL's boot header carries 512 bytes of cmdline; the packer reorders but
    # cannot shrink it, so a longer entry is unbootable on this board.
    bootargs="${ostree_karg} $(printf '%s' "$options" | tr ' ' '\n' | grep -v '^ostree=' | tr '\n' ' ')"
    bootargs="${bootargs//  / }"
    echo "  /KERNEL cmdline would be ${#bootargs} bytes (ABL limit 512)"
    [[ ${#bootargs} -le 512 ]] || \
        echo "  WARNING: over the ABL limit; drop tuning kargs before repacking"
    link="${ostree_karg#ostree=}"
    [[ -e "$SYSROOT$link" ]] || die "ostree= boot link is missing: $SYSROOT$link"
    echo "  boot link: $link"
else
    echo "  no BLS entry under $SYSROOT/boot/loader*/entries"
fi

echo
echo "flat root is unchanged: $SYSROOT/usr, $SYSROOT/etc and $SYSROOT/var are still real directories,"
echo "so the current boot payload still boots it. Booting the deployment needs a payload"
echo "that mounts this root and runs ostree-prepare-root with the ostree= karg above."
[[ $KEEP_STAGE -eq 1 ]] || run rm -rf "$STAGE"
echo
echo "undo:  rm -rf $SROOT/ostree $SROOT/boot/loader* $SROOT/boot/ostree $STAGE"
[[ -n "$MOVED_REPO" ]] && echo "       the repo this run replaced is still at $MOVED_REPO"

echo "       stage-1 can be turned off with: printf 'no\n' > $SYSROOT/etc/armada/ostree-boot"
if [[ -n "$IMAGE_REF" ]]; then
    echo "       image refs: $IMAGE_BLOB_REF  $IMAGE_STORE_REF"
    echo "       image origin: $DEPLOY_DIR/deploy/*.origin (staged in a temporary file this run removed)"
fi
