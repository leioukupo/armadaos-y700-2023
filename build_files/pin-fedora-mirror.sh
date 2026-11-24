#!/bin/bash
# Pin Fedora's two hot repositories to a mirror that does not throttle large
# RPMs. Fedora's metalink hand-picks mirrors that, from this build network,
# serve a 180 MB firmware RPM at ~30 KB/s; dnf5 has no transfer stall guard of
# its own, so the image build hangs there. Pinned baseurl removes the metalink
# entirely; if the mirror is unreachable we keep the stock metalink instead.
set -u

MIRROR="${ARMADA_FEDORA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/fedora}"

# A pinned baseurl is now a single host: a TB320FC dev build died on
# "Cannot download Packages/p/python3-cairo-1.28.0-5.fc44.aarch64.rpm: All mirrors
# were tried" while that exact RPM answered 200 on tuna, ustc, bfsu, nju, zju and
# aliyun - one stalled connection had nothing to fall back to. Restoring librepo's
# retry list costs nothing: preferred mirror first, then the other CN mirrors, each
# one probed so a dead host never enters the list.
FALLBACKS=(
    https://mirrors.ustc.edu.cn/fedora
    https://mirrors.bfsu.edu.cn/fedora
    https://mirrors.nju.edu.cn/fedora
    https://mirrors.zju.edu.cn/fedora
)

pin_file() {
    local file=$1 section=$2
    [ -f "${file}" ] || return 0
    sed -ri "/^\\[${section}\\]\$/,/^\\[/ {
        s|^metalink=|#metalink=|
        s|^#baseurl=http://download\\.example/pub/fedora/linux/|${BASEURLS}|
    }" "${file}"
}

if ! curl -fsSIL -m 20 "${MIRROR}/releases/" -o /dev/null; then
    echo "pin-fedora-mirror: ${MIRROR} unreachable, keeping Fedora metalink" >&2
    exit 0
fi

BASEURLS="baseurl=${MIRROR}/"
for candidate in "${FALLBACKS[@]}"; do
    if curl -fsSIL -m 20 "${candidate}/releases/" -o /dev/null; then
        BASEURLS="${BASEURLS}\nbaseurl=${candidate}/"
    else
        echo "pin-fedora-mirror: ${candidate} unreachable, left out" >&2
    fi
done

pin_file /etc/yum.repos.d/fedora.repo fedora
pin_file /etc/yum.repos.d/fedora-updates.repo updates
echo "pin-fedora-mirror: fedora and updates pinned to $(tr '\n' ' ' <<<"${BASEURLS}")"
grep -nE "^(baseurl|metalink)=" /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo