#!/bin/bash
set -euxo pipefail

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

# The image is committed per RUN, so anything still in the dnf download
# cache becomes part of this layer and stays in the image forever.
dnf5 -y clean all || true
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/cache/PackageKit /var/log/dnf.log*

