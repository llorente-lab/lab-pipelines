#!/bin/bash
# Sanity check run by deploy/poll_and_deploy.sh before promoting a new
# commit to `current`. Same convention as miniscope/deploy_check.sh, just
# for the CLI layer -- syntax checks only, no execution.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bash -n run
bash -n manifest.sh
bash -n resources.sh
bash -n ../setup.sh
python3 -c "import yaml; yaml.safe_load(open('../pipelines.yaml'))"
echo "cli: syntax OK (run, manifest.sh, resources.sh, ../setup.sh, pipelines.yaml)"
