#!/bin/bash
set -euxo pipefail

dnf5 -y install --setopt=install_weak_deps=False firefox

# heroic-games-launcher is a 116 MiB RPM on repos.fyralabs.com, which can
# throttle to a few hundred B/s over CN links and stall the whole image build.
# Prefer the copy staged on the build host in the read-only /mirror bind mount
# (sha256 taken from the terra44 repodata, verified there).
if ls /mirror/terra/heroic-games-launcher-*.rpm >/dev/null 2>&1; then
    dnf5 -y --nogpgcheck install --setopt=install_weak_deps=False \
        /mirror/terra/heroic-games-launcher-*.rpm
else
    dnf5 -y install --setopt=install_weak_deps=False \
        heroic-games-launcher
fi

# scx_cosmos/scx_lavd for the Armada Control scheduler setting; without the
# binaries armada-powerd reports the scheduler choice as unavailable.
dnf5 -y install --setopt=install_weak_deps=False /packages/scx-scheds/scx-scheds-[0-9]*.rpm

dnf5 -y install --setopt=install_weak_deps=False \
    --repofrompath 'copr-ublue-os-packages,https://download.copr.fedorainfracloud.org/results/ublue-os/packages/fedora-$releasever-$basearch/' \
    --setopt=copr-ublue-os-packages.gpgcheck=0 \
    --setopt=copr-ublue-os-packages.repo_gpgcheck=0 \
    flatpak \
    bazaar \
    krunner-bazaar

mkdir -p /etc/flatpak/remotes.d
# dl.flathub.org intermittently resets connections from some networks and the
# build hard-fails on it, so retry with transfer timeouts and fall back to the
# copy vendored in the build context (the GPG key in it is the long-lived
# Flathub repo signing key; refresh it manually if flathub ever rotates keys).
flathub_repo=/etc/flatpak/remotes.d/flathub.flatpakrepo
flathub_ok=0
for flathub_url in \
        https://dl.flathub.org/repo/flathub.flatpakrepo \
        https://dl.flathub.net/repo/flathub.flatpakrepo; do
    if curl --retry 3 --retry-delay 5 --connect-timeout 15 \
            --speed-limit 2000 --speed-time 20 -fsSL -o "${flathub_repo}.tmp" "${flathub_url}" &&
            [[ -s "${flathub_repo}.tmp" ]]; then
        mv -f "${flathub_repo}.tmp" "${flathub_repo}"
        flathub_ok=1
        break
    fi
    rm -f "${flathub_repo}.tmp"
done
if [[ ${flathub_ok} != 1 ]]; then
    echo "10-base-packages: flathub.flatpakrepo download failed, using vendored copy" >&2
    install -m 0644 "$(dirname "${BASH_SOURCE[0]}")/flathub.flatpakrepo" "${flathub_repo}"
fi
grep -q "^Url=" "${flathub_repo}"

