#!/bin/bash
# Sanity check run by deploy/poll_and_deploy.sh before promoting a new commit
# to `current`. Deliberately fast and dependency-light (plain system
# python3, no Apptainer, no Sherlock resources) since it runs on the login
# node as part of every deploy, not just when someone remembers to test.
#
# Add more checks here over time; keep it under a few seconds. Anything
# needing the container or real Drive/scratch access belongs in
# tests/run_mc_sync_test.sbatch instead, run manually or on a separate
# schedule, not gating every deploy.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

python3 tests/test_reconcile_common.py
