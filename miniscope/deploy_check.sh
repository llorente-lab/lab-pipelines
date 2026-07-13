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

# scrontab jobs run in a minimal, non-login environment: no ~/.bashrc, and
# Sherlock's default python3 predates 3.7, missing `from __future__ import
# annotations` (used in reconcile_common.py). Same situation as git in
# deploy/poll_and_deploy.sh -- load a modern interpreter explicitly rather
# than assuming the invoking shell already has one.
if ! type module >/dev/null 2>&1; then
  for lmod_init in /etc/profile.d/lmod.sh /etc/profile.d/z00_lmod.sh \
                   /share/software/lmod/lmod/init/bash; do
    [ -f "$lmod_init" ] && source "$lmod_init" && break
  done
fi
if type module >/dev/null 2>&1; then
  module load system git >/dev/null 2>&1 || true
  module load python/3.9.0 >/dev/null 2>&1 || true
fi

python3 tests/test_reconcile_common.py
