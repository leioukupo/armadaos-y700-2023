#!/bin/bash
# Pin Fedora's two hot repositories to a mirror that does not throttle large
# RPMs. Fedora's metalink hand-picks mirrors that, from this build network,
# serve a 180 MB firmware RPM at ~30 KB/s; dnf5 has no transfer stall guard of
# its own, so the image build hangs there. Pinned baseurl removes the metalink
# entirely; if the mirror is unreachable we keep the stock metalink instead.
set -u

MIRROR="${ARMADA_FEDORA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/fedora}"

# Two things about a CN build network: the pinned mirror is reached 140x faster
# directly than through the Clash proxy the rest of the build uses (9.2 MB/s vs
# 66 KB/s for one wpa_supplicant RPM), and a pinned baseurl is a single host with no
# retry list. A TB320FC dev build died on "Cannot download
# Packages/p/python3-cairo-1.28.0-5.fc44.aarch64.rpm: All mirrors were tried" while
# that same RPM answered HTTP 200 from tuna, ustc, bfsu, nju, zju and aliyun - one
# stalled connection had nothing to fall back to.
# Restoring librepo's retry list costs nothing: preferred mirror first, then the other
# CN mirrors, each one probed so a dead host never enters the list.
# Ranked by what they actually served from this network (range GET, same file):
# nju 1.5 MB/s, bfsu 0.90 MB/s, aliyun 0.82 MB/s, tuna 0.40 MB/s, ustc 0.25 MB/s,
# zju 0.11 MB/s. zju is dropped entirely: two builds ended in "All mirrors were tried"
# on files it served under 1 KB/s, and it is the only one with no peer at that speed.
FALLBACKS=(
    https://mirrors.nju.edu.cn/fedora
    https://mirrors.bfsu.edu.cn/fedora
    https://mirrors.ustc.edu.cn/fedora
    https://mirrors.aliyun.com/fedora
)

pin_file() {
    local file=$1 section=$2
    [ -f "${file}" ] || return 0
    sed -ri "/^\\[${section}\\]\$/,/^\\[/ {
        s|^metalink=|#metalink=|
        s|^#baseurl=http://download\\.example/pub/fedora/linux/(.*)$|${BASEURLS}${PROXY_LINE}\nretries=${RETRIES}|
    }" "${file}"
}

if ! curl -fsSIL -m 20 "${MIRROR}/releases/" -o /dev/null; then
    echo "pin-fedora-mirror: ${MIRROR} unreachable, keeping Fedora metalink" >&2
    exit 0
fi

# The example line carries the repo path (releases/$releasever/Everything/$basearch/os/
# for fedora, updates/$releasever/Everything/$basearch/ for updates) and the two
# sections differ, so every mirror has to re-attach it through \1. Attaching it to the
# last entry only leaves the others pointing at the mirror root, which reads as a
# working retry list and 404s on every package.
BASE_LIST=("${MIRROR}")
for candidate in "${FALLBACKS[@]}"; do
    if curl -fsSIL -m 20 "${candidate}/releases/" -o /dev/null; then
        BASE_LIST+=("${candidate}")
    else
        echo "pin-fedora-mirror: ${candidate} unreachable, left out" >&2
    fi
done
BASEURLS=""
for mirror in "${BASE_LIST[@]}"; do
    BASEURLS="${BASEURLS}baseurl=${mirror}/\\1\\n"
done
BASEURLS="${BASEURLS%\\n}"

# dnf5's own repo option, so the fix does not depend on how librepo parses NO_PROXY:
# a leading-dot entry did not bypass the proxy here, and these mirrors are exactly the
# hosts the proxy is useless for. ARMADA_FEDORA_PROXY=_none_ keeps that behaviour
# selectable for a host that really does need the proxy for them.
# One stalled connection must not end the transaction: librepo gave up after two
# attempts on wpa_supplicant and fuse while the same RPMs sit on four other mirrors.
RETRIES="${ARMADA_FEDORA_RETRIES-8}"
REPO_PROXY="${ARMADA_FEDORA_PROXY-_none_}"
PROXY_LINE=""
if [ -n "${REPO_PROXY}" ]; then
    PROXY_LINE="\\nproxy=${REPO_PROXY}"
fi

pin_file /etc/yum.repos.d/fedora.repo fedora
pin_file /etc/yum.repos.d/fedora-updates.repo updates
echo "pin-fedora-mirror: fedora and updates pinned to ${BASE_LIST[*]}"
grep -nE "^(baseurl|proxy|retries|metalink)=" /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo