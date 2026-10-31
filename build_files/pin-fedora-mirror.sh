#!/bin/bash
# Pin Fedora's two hot repositories to a mirror that does not throttle large
# RPMs. Fedora's metalink hand-picks mirrors that, from this build network,
# serve a 180 MB firmware RPM at ~30 KB/s; dnf5 has no transfer stall guard of
# its own, so the image build hangs there. Pinned baseurl removes the metalink
# entirely; if the mirror is unreachable we keep the stock metalink instead.
set -u

MIRROR="${ARMADA_FEDORA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/fedora}"

pin_file() {
    local file=$1 section=$2
    [ -f "${file}" ] || return 0
    sed -ri "/^\\[${section}\\]\$/,/^\\[/ {
        s|^metalink=|#metalink=|
        s|^#baseurl=http://download\\.example/pub/fedora/linux/|baseurl=${MIRROR}/|
    }" "${file}"
}

if ! curl -fsSIL -m 20 "${MIRROR}/releases/" -o /dev/null; then
    echo "pin-fedora-mirror: ${MIRROR} unreachable, keeping Fedora metalink" >&2
    exit 0
fi

pin_file /etc/yum.repos.d/fedora.repo fedora
pin_file /etc/yum.repos.d/fedora-updates.repo updates
echo "pin-fedora-mirror: fedora and updates pinned to ${MIRROR}"
grep -nE "^(baseurl|metalink)=" /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo