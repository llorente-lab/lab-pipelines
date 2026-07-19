#!/bin/bash
# Aggregates every session's proc/ output into aggregate_results/ and
# (re)generates moseq2-index.yaml. --output/--error passed by
# submit_moseq.py as explicit sbatch CLI flags, not set here -- see
# extract_session.sbatch's header comment for why.
#SBATCH --job-name=moseq-aggregate
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=04:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch aggregate.sbatch <project_root>" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

_JOB_START="$(date -Iseconds)"
_STATUS_FILE="$PROJECT_ROOT/status/aggregate.json"
mkdir -p "$PROJECT_ROOT/status"
_record_status() {
  local rc=$?
  local st; st="$([ "$rc" -eq 0 ] && echo completed || echo failed)"
  printf '{"stage":"aggregate","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}\n' \
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
echo ">>> AGGREGATE START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-extract aggregate-results \
  --input-dir "$PROJECT_ROOT" \
  --output-dir "$PROJECT_ROOT/aggregate_results/"

apptainer_exec moseq2-extract generate-index \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-file "$PROJECT_ROOT/moseq2-index.yaml"

echo "------------------------------------------------------------------"
echo ">>> AGGREGATE END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
