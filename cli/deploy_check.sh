#!/bin/bash
# Sanity check run by deploy/poll_and_deploy.sh before promoting a new commit
# to `current` -- same convention as miniscope/deploy_check.sh, just for the
# CLI layer instead. Kept fast and dependency-light: pure syntax checking,
# no execution, since everything here is plain bash with no external
# dependencies beyond what's already required by every other check.
#
# setup.sh lives at the repo root, not here -- there is no cli/setup.sh
# shim (removed; nothing in the repo references the old path anymore).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bash -n run
bash -n manifest.sh
bash -n resources.sh
bash -n ../setup.sh
python3 -c "import yaml; yaml.safe_load(open('../pipelines.yaml'))"
echo "cli: syntax OK (run, manifest.sh, resources.sh, ../setup.sh, pipelines.yaml)"
