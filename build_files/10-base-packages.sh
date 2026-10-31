#!/bin/bash
# The base package set is split into three scripts so that a build running on
# the device can commit them as separate image layers: one layer holding every
# base package needs about three copies of itself on disk while it is committed,
# which does not fit on a 57 GB eMMC. Running this file installs all three groups
# in the original order, which is what upstream CI does.
set -euxo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${here}/10a-core.sh"
bash "${here}/10b-desktop.sh"
bash "${here}/10c-apps.sh"
