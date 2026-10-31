#!/bin/bash
set -euxo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/pin-fedora-mirror.sh"

dnf5 -y install --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release

dnf5 -y install --setopt=install_weak_deps=False \
    sddm \
    pipewire \
    pipewire-alsa \
    pipewire-pulseaudio \
    pulseaudio-utils \
    wireplumber \
    ladspa-swh-plugins \
    alsa-lib \
    alsa-ucm \
    alsa-utils \
    qcom-firmware \
    atheros-firmware \
    NetworkManager \
    NetworkManager-wifi \
    wpa_supplicant \
    bluez \
    dbus-broker \
    python3-gobject \
    iio-sensor-proxy \
    gtk4 \
    libadwaita \
    python3-websocket-client \
    python3-vdf \
    polkit \
    upower \
    sudo \
    rsync \
    curl \
    git \
    jq \
    newt \
    python-unversioned-command \
    lsb_release \
    htop \
    lsof \
    unzip \
    fuse \
    fuse-libs \
    libxcrypt-compat \
    sdl2-compat \
    evtest \
    libgpiod-utils \
    dbus-x11 \
    xdg-user-dirs \
    xdg-terminal-exec \
    desktop-file-utils \
    btrfs-progs \
    parted \
    gdisk \
    binutils \
    blas \
    bzip2-libs \
    lapack \
    xz \
    dracut \
    dracut-config-generic \
    qt6-qttools \
    qt6-qtvirtualkeyboard \
    zenity \
    seatd \
    cage \
    wlr-randr \
    distrobox \
    wl-clipboard \
    btop \
    tailscale

# negativo17.org throttles to about 10 KB/s from CN links, and the whole rootfs
# is one RUN layer: a stalled download there costs a full rebuild. The build
# host stages the fedora-multimedia closure in /mirror/neg17 (read-only bind
# mount); dnf5 still solves every dependency against the Fedora repos, so a
# missing RPM fails loudly instead of silently shrinking the image.
if compgen -G "/mirror/neg17/*.rpm" > /dev/null; then
    dnf5 -y --nogpgcheck install --setopt=install_weak_deps=False /mirror/neg17/*.rpm
else
    curl --connect-timeout 30 --max-time 120 --retry 3 -fsSL \
        -o /etc/yum.repos.d/negativo17-fedora-multimedia.repo \
        https://negativo17.org/repos/fedora-multimedia.repo

    dnf5 -y install --setopt=install_weak_deps=False \
        ffmpeg \
        ffmpeg-libs \
        libavcodec \
        libfdk-aac \
        gstreamer1-plugins-ugly \
        gstreamer1-plugin-libav
fi

for multimedia in ffmpeg ffmpeg-libs libavcodec libfdk-aac \
                  gstreamer1-plugins-ugly gstreamer1-plugin-libav; do
    rpm -q "${multimedia}" >/dev/null || {
        echo "ERROR: ${multimedia} is not installed" >&2
        exit 1
    }
done

# Install the remaining plugins from Fedora; Negativo17's full -bad package
# pulls a large soundfont payload that Armada does not need.
rm -f /etc/yum.repos.d/negativo17-fedora-multimedia.repo

dnf5 -y install --setopt=install_weak_deps=False \
    gstreamer1-plugins-good \
    gstreamer1-plugins-bad-free \
    gstreamer1-plugin-openh264 \
    gstreamer1-plugin-dav1d

dnf5 -y install --setopt=install_weak_deps=False \
    /packages/umtp-responder/umtp-responder-*.rpm

# kshim-tools scripts run under python3 and call dtc, gzip and openssl.
dnf5 -y install --setopt=install_weak_deps=False \
    python3 \
    dtc \
    gzip \
    openssl

# CachyOS Proton's ARM64 GStreamer asks for Arch's libbz2 soname.
ln -sf libbz2.so.1 /usr/lib64/libbz2.so.1.0

# Some AppImages link zlib's unversioned development soname.
ln -sf libz.so.1 /usr/lib64/libz.so

# pressure-vessel needs en_US.UTF-8; Plasma needs zh_CN.UTF-8 for Chinese.
dnf5 -y install --setopt=install_weak_deps=False \
    glibc-langpack-en \
    glibc-langpack-zh

dnf5 -y install --setopt=install_weak_deps=False \
    google-noto-sans-vf-fonts \
    google-noto-sans-cjk-fonts \
    google-noto-sans-thai-vf-fonts \
    google-noto-sans-arabic-vf-fonts \
    google-noto-sans-hebrew-vf-fonts \
    google-noto-sans-devanagari-vf-fonts \
    google-noto-color-emoji-fonts \
    google-noto-sans-mono-fonts

# Weak dependencies are disabled, so install Plasma's Qt translation catalogs.
dnf5 -y install --setopt=install_weak_deps=False \
    qt6-qttranslations \
    plasma-workspace \
    plasma-desktop \
    plasma-mobile \
    plasma-settings \
    plasma-pa \
    plasma-nm \
    bluedevil \
    maliit-keyboard \
    libappindicator-gtk3 \
    libdbusmenu-gtk3 \
    kdialog \
    kio-extras \
    libsmbclient \
    cifs-utils \
    waydroid \
    kscreen \
    konsole \
    qmlkonsole \
    dolphin \
    ark \
    gwenview \
    kwrite

# feedbackd's role-routing sinks can wedge Steam audio during session startup.
rm -f /usr/share/wireplumber/wireplumber.conf.d/media-role-nodes.conf

# Patched KWin lets devices pin Plasma's virtual keyboard to a configured output.
dnf5 -y install --setopt=install_weak_deps=False \
    /packages/kwin/kwin-[0-9]*.rpm \
    /packages/kwin/kwin-common-[0-9]*.rpm \
    /packages/kwin/kwin-libs-[0-9]*.rpm

# Carry Plasma Mobile's input-region crash fix until Fedora backports it.
dnf5 -y install --setopt=install_weak_deps=False \
    /packages/plasma-mobile/plasma-mobile-[0-9]*.rpm \
    /packages/plasma-mobile/plasma-lookandfeel-fedora-mobile-[0-9]*.rpm

# PowerDevil's KWin backend treats 0 as safe; reserve 5% for internal panels.
dnf5 -y install --setopt=install_weak_deps=False /packages/powerdevil/powerdevil-*.fc44.armada.*.rpm

dnf5 -y install --setopt=install_weak_deps=False firefox

dnf5 -y install --setopt=install_weak_deps=False \
    heroic-games-launcher

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
