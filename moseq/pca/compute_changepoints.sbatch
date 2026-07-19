#!/bin/bash
# Model-free syllable changepoints from PCA scores. Optional in moseq2's
# own workflow, but useful as the target-duration reference for kappa
# selection later. Same --cluster-type local reasoning as the other
# PCA-stage jobs. --output/--error passed by submit_moseq.py as explicit
# sbatch CLI flags -- see extract_session.sbatch's header comment.
#SBATCH --job-name=moseq-changepoints
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=1-00:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch compute_changepoints.sbatch <project_root> [config_file] [pca_file_components] [pca_file_scores]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${2:-$PROJECT_ROOT/config.yaml}"
PCA_FILE_COMPONENTS="${3:-$PROJECT_ROOT/_pca/pca.h5}"
PCA_FILE_SCORES="${4:-$PROJECT_ROOT/_pca/pca_scores.h5}"

_JOB_START="$(date -Iseconds)"
_STATUS_FILE="$PROJECT_ROOT/status/changepoints.json"
mkdir -p "$PROJECT_ROOT/status"
_record_status() {
  local rc=$?
  local st; st="$([ "$rc" -eq 0 ] && echo completed || echo failed)"
  printf '{"stage":"changepoints","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}\n' \
    "$st" "$_JOB_START" "$(date -Iseconds)" "$rc" \
    "${SLURMD_NODENAME:-}" "${SLURM_JOB_ID:-}" > "$_STATUS_FILE"
}
trap _record_status EXIT

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK

echo "------------------------------------------------------------------"
echo ">>> CHANGEPOINTS START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-pca compute-changepoints \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --pca-file-components "$PCA_FILE_COMPONENTS" \
  --pca-file-scores "$PCA_FILE_SCORES" \
  --cluster-type local \
  --nworkers 1 \
  --cores "$SLURM_CPUS_PER_TASK"

echo "------------------------------------------------------------------"
echo ">>> CHANGEPOINTS END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
