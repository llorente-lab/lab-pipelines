#!/bin/bash
# Sanity check run by deploy/poll_and_deploy.sh before promoting a new commit
# to `current`. Same fast, dependency-light philosophy as
# miniscope/deploy_check.sh -- no Apptainer, no Sherlock resources, just
# syntax/shape checks that catch typos before they reach `current`.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bash -n common/env_setup.sh
bash -n jupyter_kernel/moseq_kernel_wrapper.sh

python3 -c "import json; json.load(open('jupyter_kernel/kernel.json'))"

# reconcile_moseq_progress.py imports moseq2_app (needs the container), so
# it's deliberately NOT checked here -- same reasoning as
# miniscope/deploy_check.sh excluding test_path_resolution.py. Only the
# pure-stdlib extraction-status check runs as part of the fast deploy gate.
python3 tests/test_reconcile_moseq_extraction.py
