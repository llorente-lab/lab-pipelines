#!/bin/bash
#SBATCH --job-name=multisession_registration
# Resources come from the registry (miniscope/resources.yaml) when submitted via `run`.
#SBATCH --partition=illorent
#SBATCH --nodes=1
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
# shellcheck disable=SC1091
source "$CAIMAN_ROOT_DIR/../moseq/common/monitor_resources.sh"
set -euo pipefail

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Args: $*"

mkdir -p "$SCRATCH/logs/resource_monitor"
start_resource_monitor "$SCRATCH/logs/resource_monitor/multisession_${SLURM_JOB_ID}.tsv"

apptainer exec \
  --env "RCLONE_CONFIG=${RCLONE_CONFIG}" \
  --env "PYTHONNOUSERSITE=1" \
  --env "PYTHONPATH=${CAIMAN_COMMON_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
  --env "SCRATCH=${SCRATCH}" \
  "$SIF" python "$CAIMAN_ROOT_DIR/multisession/multisession_registration.py" "$@"

echo "==== JOB END: $(date) ===="
