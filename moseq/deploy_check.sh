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
