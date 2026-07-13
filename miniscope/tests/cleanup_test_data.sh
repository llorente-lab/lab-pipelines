#!/bin/bash
# Removes everything run_mc_sync_test.sbatch (or a manual test run) leaves
# behind, both on local scratch and on the Drive test sandbox. Safe to run
# any time; does nothing if the test hasn't been run yet.
#
# Usage: bash cleanup_test_data.sh

CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/miniscope}"
source "$CAIMAN_ROOT/common/env_setup.sh"
set -euo pipefail

LOCAL_DIR="$SCRATCH/Miniscope/_pipeline_test"
DRIVE_DIR="gdrive:Miniscope/_pipeline_test"

echo "removing local test data: $LOCAL_DIR"
rm -rf "$LOCAL_DIR"

echo "removing Drive test sandbox: $DRIVE_DIR"
apptainer_rclone purge "$DRIVE_DIR" 2>/dev/null || echo "nothing on Drive to remove (or already clean)"

echo "cleanup complete"
