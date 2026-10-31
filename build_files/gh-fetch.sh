#!/bin/bash
# GitHub release/raw assets are unreliable from some CN networks: connections
# stall at ~0 B/s and curl then hangs with no transfer timeout. Try known
# GitHub proxies first, abort any transfer that goes quiet, and keep the
# origin as the last resort. Callers still verify sha256/sha512 themselves.
GH_PROXIES=(
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    "https://gh-proxy.org/"
    "https://ghproxy.net/"
)

armada_fetch() {
    local out=$1 url=$2 proxy
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
