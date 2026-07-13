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

# Normally this script is invoked as a child process of
# deploy/poll_and_deploy.sh, which already prepends a modern python3 onto
# PATH before calling this (confirmed necessary: Lmod's `module load` does
# not reliably activate inside a scrontab-launched batch job on Sherlock,
# so this can't just rely on `module` working). The prepend below is
# belt-and-suspenders for when this script gets run standalone instead,
# e.g. manually while testing -- same hardcoded path, kept in sync with
# poll_and_deploy.sh's GIT_MODULE_BIN/PYTHON_MODULE_BIN.
PYTHON_MODULE_BIN="/share/software/user/open/python/3.9.0/bin"
[ -d "$PYTHON_MODULE_BIN" ] && PATH="$PYTHON_MODULE_BIN:$PATH"

python3 tests/test_reconcile_common.py
