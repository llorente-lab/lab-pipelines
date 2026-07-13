#!/bin/bash
# Sanity check run by deploy/poll_and_deploy.sh before promoting a new commit
# to `current` -- same convention as miniscope/deploy_check.sh, just for the
# CLI layer instead. Kept fast and dependency-light: pure syntax checking,
# no execution, since `run` and `setup.sh` are both plain bash with no
# external dependencies beyond what's already required by every other check.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bash -n run
bash -n setup.sh
echo "cli: syntax OK (run, setup.sh)"
