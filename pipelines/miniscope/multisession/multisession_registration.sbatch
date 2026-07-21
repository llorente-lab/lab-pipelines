#!/bin/bash
#SBATCH --job-name=multisession_registration
#SBATCH --partition=illorent
#SBATCH --nodes=1
#SBATCH --time=4:00:00
# No --output/--error: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh) route logs to
# $SCRATCH/logs/miniscope_multisession/.

CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/pipelines/miniscope}"
source "$CAIMAN_ROOT/common/env_setup.sh"
# shellcheck disable=SC1091
source "$REPO_COMMON_DIR/monitor_resources.sh"
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
