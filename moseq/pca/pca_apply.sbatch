#!/bin/bash
# Projects extracted sessions onto an already-fit PCA basis. Same
# --cluster-type local reasoning as pca_fit.sbatch. Also the job to
# (re)run, cheaply, whenever new sessions are added to an existing project
# -- no PCA refit needed. --output/--error passed by submit_moseq.py as
# explicit sbatch CLI flags -- see extract_session.sbatch's header comment.
#SBATCH --job-name=moseq-pca-apply
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
  echo "usage: sbatch pca_apply.sbatch <project_root> [config_file] [pca_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${2:-$PROJECT_ROOT/config.yaml}"
PCA_FILE="${3:-$PROJECT_ROOT/_pca/pca.h5}"

_JOB_START="$(date -Iseconds)"
_STATUS_FILE="$PROJECT_ROOT/status/pca_apply.json"
mkdir -p "$PROJECT_ROOT/status"
_record_status() {
  local rc=$?
  local st; st="$([ "$rc" -eq 0 ] && echo completed || echo failed)"
  printf '{"stage":"pca_apply","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}\n' \
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
echo ">>> PCA APPLY START: $(date)"
echo "Project  => $PROJECT_ROOT"
echo "Config   => $CONFIG_FILE"
echo "PCA file => $PCA_FILE"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-pca apply-pca \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --pca-file "$PCA_FILE" \
  --cluster-type local \
  --nworkers 1 \
  --cores "$SLURM_CPUS_PER_TASK" \
  --overwrite-pca-apply true

echo "------------------------------------------------------------------"
echo ">>> PCA APPLY END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
