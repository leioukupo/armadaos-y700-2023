#!/usr/bin/env bash
# Prints the container platform a package has to be built for.
#
# Armada images are arm64, so a package built for another arch either fails its
# own build (the spec mixes -m64 with -march=armv8.2-a) or, worse, publishes an
# artifact the arm64 image build cannot install. Only the packages that
# deliberately cross-build from an x86_64 host differ.
set -euo pipefail

pkg="${1:?usage: target-platform.sh <package>}"

case "${pkg}" in
    # These cross-build to arm64 on purpose, so they run on an x86_64 host.
    mesa-android|lepton|mesa-x86) printf 'linux/amd64\n' ;;
    *)                            printf 'linux/arm64\n' ;;
esac
