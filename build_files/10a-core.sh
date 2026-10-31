#!/bin/bash
set -euxo pipefail

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

# The image is committed per RUN, so anything still in the dnf download
# cache becomes part of this layer and stays in the image forever.
dnf5 -y clean all || true
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/cache/PackageKit /var/log/dnf.log*

