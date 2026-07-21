#!/bin/bash
# Shared sbatch job boilerplate for any pipeline's stage scripts. Originally
# written for Moseq (extract, aggregate, pca_fit, pca_apply,
# compute_changepoints, kappa_scan, learn_model) 
#
# job_init:
#   - validates project_root was given (usage message auto-derived from
#     $0, so it's always correct for whichever script sourced this)
#   - resolves $PROJECT_ROOT to an absolute path (re-exported as a global,
#     same variable name every stage script already used)
#   - sets up <project_root>/status/<stage>.json (latest run only, kept for
#     backward compat) + <project_root>/status/history.jsonl (append-only,
#     every run ever) via the EXIT trap that writes completed/failed to
#     both. Shared by every pipeline that sources this file, so both
#     moseq and miniscope get run history for free.

_JOB_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_JOB_TEMPLATE_DIR/monitor_resources.sh"

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"


job_init() {
  local stage="$1"
  local project_root="$2"

  if [ -z "$project_root" ]; then
    echo "usage: sbatch $(basename "$0") <project_root> [...]" >&2
    exit 1
  fi
  PROJECT_ROOT="$(cd "$project_root" && pwd)"

  _JOB_START="$(date -Iseconds)"
  _STAGE="$stage"
  _STATUS_FILE="$PROJECT_ROOT/status/${stage}.json"
  _HISTORY_FILE="$PROJECT_ROOT/status/history.jsonl"
  mkdir -p "$PROJECT_ROOT/status"
  _record_status() {
    local rc=$?
    local st; st="$([ "$rc" -eq 0 ] && echo completed || echo failed)"
    local record
    record="$(printf '{"stage":"%s","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}' \
      "$_STAGE" "$st" "$_JOB_START" "$(date -Iseconds)" "$rc" \
      "${SLURMD_NODENAME:-}" "${SLURM_JOB_ID:-}")"
    echo "$record" > "$_STATUS_FILE"
    echo "$record" >> "$_HISTORY_FILE"
  }
  trap _record_status EXIT

  export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
  export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK
}

moseq_job_init() { job_init "$@"; }
