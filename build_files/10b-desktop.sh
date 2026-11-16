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
#
# Fedora 44 split kglobalacceld and kdecoration out of the kwin SRPM. A locally
# pinned kwin drags the rest of Plasma back to its own era, but those two
# split-out libraries only exist in the repository at the newer version, so the
# image ends up with e.g. kwin 6.7.5 against kglobalacceld 6.8.2 and
# kwin_wayland dies on an undefined KGlobalAccelD symbol the moment a session
# starts. Builds that do not need Armada's KWin/PowerDevil patches take the
# whole Plasma set from the repository instead, so every piece agrees.
if [[ "${ARMADA_PLASMA_FROM_REPO:-0}" = 1 ]]; then
    dnf5 -y install --setopt=install_weak_deps=False \
        kwin kwin-common kwin-libs kglobalacceld kdecoration powerdevil
else
    dnf5 -y install --setopt=install_weak_deps=False \
        /packages/kwin/kwin-[0-9]*.rpm \
        /packages/kwin/kwin-common-[0-9]*.rpm \
        /packages/kwin/kwin-libs-[0-9]*.rpm

    # PowerDevil's KWin backend treats 0 as safe; reserve 5% for internal panels.
    dnf5 -y install --setopt=install_weak_deps=False /packages/powerdevil/powerdevil-*.fc44.armada.*.rpm
fi

# Gate: the Plasma core set must agree on one version, and KWin must resolve.
verify_plasma_set() {
    local pkgs versions unresolved
    pkgs=(kwin kwin-libs kglobalacceld kdecoration plasma-workspace
          plasma-workspace-libs plasma-desktop plasma-mobile powerdevil)
    versions=$(LC_ALL=C rpm -q --qf '%{version}\n' "${pkgs[@]}" | sort -u)
    if [[ $(wc -l <<< "${versions}") -ne 1 ]]; then
        echo "PLASMA_VERSION_SPREAD:"
        LC_ALL=C rpm -q --qf '%{name} %{version}\n' "${pkgs[@]}" | sort -k2
        return 1
    fi
    # grep -c exits 1 when nothing matches, which under set -e -o pipefail would
    # fail the build for the passing case, so let the zero-count path through.
    unresolved=$(LD_BIND_NOW=1 ldd -r /usr/bin/kwin_wayland 2>&1 | grep -c 'undefined symbol' || true)
    if [[ "${unresolved}" != 0 ]]; then
        echo "KWIN_UNRESOLVED_SYMBOLS=${unresolved}"
        LD_BIND_NOW=1 ldd -r /usr/bin/kwin_wayland 2>&1 | grep 'undefined symbol' | head -6
        return 1
    fi
    echo "PLASMA_SET_OK version=${versions} unresolved=0"
}
verify_plasma_set

