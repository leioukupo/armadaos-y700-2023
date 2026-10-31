#!/bin/bash
set -euxo pipefail

cd /ctx/build_files

run_step() {
    local step="${1#./}"
    local start="${SECONDS}"

    "$@"
    printf '%s completed in %d seconds\n' "${step}" "$((SECONDS - start))"
}

ALL_STEPS=(
    10-base-packages.sh
    20-install-kernel.sh
    30-install-steam-session.sh
    40-vendor-system-files.sh
    45-install-decky-plugins.sh
    46-install-bundled-plugins.sh
    50-create-user.sh
    52-configure-os-release.sh
    55-generate-initramfs.sh
    60-set-default-target.sh
    70-cleanup.sh
    80-finalize-update-state.sh
)

# Without arguments every step runs, which is what upstream CI relies on.
# Passing step-number prefixes lets one image be built across several RUN
# instructions: each committed layer stays small enough that a build running
# on the device itself can commit it without running the root filesystem out
# of space, and a failed attempt keeps the layers it already committed.
steps=()
if [[ $# -eq 0 ]]; then
    steps=("${ALL_STEPS[@]}")
else
    for step in "${ALL_STEPS[@]}"; do
        for prefix in "$@"; do
            if [[ "${step}" == "${prefix}-"* ]]; then
                steps+=("${step}")
                break
            fi
        done
    done
    if [[ ${#steps[@]} -eq 0 ]]; then
        printf 'build.sh: no build steps match: %s\n' "$*" >&2
        exit 1
    fi
fi

for step in "${steps[@]}"; do
    run_step "./${step}"
done