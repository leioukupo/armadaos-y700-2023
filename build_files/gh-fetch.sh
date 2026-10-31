#!/bin/bash
# GitHub release/raw assets are unreliable from some CN networks: connections
# stall at ~0 B/s and curl then hangs with no transfer timeout. Try files
# staged in the host-side build mirror first, then an HTTP proxy that can
# reach GitHub, then the public GitHub mirrors, and keep the origin as the
# last resort. Callers still verify sha256/sha512 themselves.
GH_PROXIES=(
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    "https://gh-proxy.org/"
    "https://ghproxy.net/"
)

# Upstream HTTP proxy for GitHub assets: build_files/gh-proxy.conf holds one
# proxy URL (http://host:port). ARMADA_HTTP_PROXY overrides the file so CI,
# which has no such LAN, keeps using the mirrors below.
GH_UPSTREAM_PROXY="${ARMADA_HTTP_PROXY:-}"
if [[ -z "${GH_UPSTREAM_PROXY}" ]] && [[ -r /ctx/build_files/gh-proxy.conf ]]; then
    GH_UPSTREAM_PROXY="$(grep -m1 -Eo 'https?://[^[:space:]]+' /ctx/build_files/gh-proxy.conf || true)"
fi

armada_fetch() {
    local out=$1 url=$2 base proxy
    base="$(basename "${url}")"

    # build.sh mounts the host mirror read-only at /mirror; assets staged there
    # never touch the network at all.
    if [[ -r "/mirror/${base}" ]]; then
        echo "fetch via /mirror/${base}" >&2
        if cp -f "/mirror/${base}" "${out}" && [[ -s "${out}" ]]; then
            return 0
        fi
        rm -f "${out}"
    fi

    if [[ -n "${GH_UPSTREAM_PROXY}" ]]; then
        echo "fetch via proxy ${GH_UPSTREAM_PROXY} ${url}" >&2
        if curl --proxy "${GH_UPSTREAM_PROXY}" --retry 3 --retry-delay 5 \
            --connect-timeout 15 --speed-limit 100000 --speed-time 180 \
            -fsSL -o "${out}" "${url}"; then
            [[ -s "${out}" ]] && return 0
        fi
        rm -f "${out}"
    fi

    for proxy in "${GH_PROXIES[@]}"; do
        echo "fetch via ${proxy}${url}" >&2
        if curl --retry 2 --retry-delay 3 --connect-timeout 15 \
            --speed-limit 200000 --speed-time 25 -fsSL -o "${out}" "${proxy}${url}"; then
            [[ -s "${out}" ]] && return 0
        fi
        rm -f "${out}"
    done

    echo "fetch via ${url}" >&2
    curl --retry 12 --retry-delay 10 --connect-timeout 20 \
        --speed-limit 200000 --speed-time 60 -fsSL -o "${out}" "${url}"
}