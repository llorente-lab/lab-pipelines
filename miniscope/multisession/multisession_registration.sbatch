#!/bin/bash
#SBATCH --job-name=multisession_registration
#SBATCH --partition=illorent
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=4:00:00
# No --output/--error here: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh,
# sourced via ~/.bashrc) route logs to $SCRATCH/logs/miniscope_multisession/.
#
# Runs multisession spatial registration for one or all mice.
# All args are passed through to multisession_registration.py:
#
#   sbatch multisession_registration.sbatch                  # all mice
#   sbatch multisession_registration.sbatch --mouse VK_...  # one mouse
#   sbatch multisession_registration.sbatch --force          # rerun even if done

CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/miniscope}"
source "$CAIMAN_ROOT/common/env_setup.sh"
set -euo pipefail

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Args: $*"

apptainer exec \
  --env "RCLONE_CONFIG=${RCLONE_CONFIG}" \
  --env "PYTHONNOUSERSITE=1" \
  --env "PYTHONPATH=${CAIMAN_COMMON_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
  --env "SCRATCH=${SCRATCH}" \
  "$SIF" python "$CAIMAN_ROOT_DIR/multisession/multisession_registration.py" "$@"

echo "==== JOB END: $(date) ===="
