#!/bin/bash
# Shared sbatch job boilerplate for every Moseq stage script (extract,
# aggregate, pca_fit, pca_apply, compute_changepoints, kappa_scan,
# learn_model). Factored out after the numexpr thread-cap fix had to be
# applied to all 7 scripts individually one at a time -- that class of bug
# (a fix applied to one copy but not propagated to the others) is exactly
# what this file exists to prevent going forward. If a stage needs its own
# extra threading/status behavior, add it AFTER calling moseq_job_init
# below, don't fork this file.
#
# Usage, at the top of a stage script (after `set -euo pipefail` and
# sourcing env_setup.sh, since this relies on $MOSEQ_COMMON_DIR being
# exported already):
#
#   source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
#   source "$MOSEQ_COMMON_DIR/template.sh"
#
#   PROJECT_ROOT="${1-}"
#   CONFIG_FILE="${2-}"          # or whatever a given stage's own args are
#   moseq_job_init "extract" "$PROJECT_ROOT"
#   CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"
#
# moseq_job_init:
#   - validates project_root was given (usage message auto-derived from
#     $0, so it's always correct for whichever script sourced this)
#   - resolves $PROJECT_ROOT to an absolute path (re-exported as a global,
#     same variable name every stage script already used)
#   - sets up <project_root>/status/<stage>.json + the EXIT trap that
#     writes completed/failed to it
#   - exports the six thread-count env vars every stage needs so the
#     container's numeric libraries match this job's actual Slurm
#     allocation (this is what NUMEXPR_MAX_THREADS's 64-thread default cap
#     was blowing past before -- see git history on any of the stage
#     scripts for that saga)
#
# Deliberately a function, not top-level script code: sourcing this file
# must not have side effects until moseq_job_init is actually called,
# since a stage script may need to do its own arg-parsing (default values,
# optional positional args) BEFORE project_root's presence is validated.

# shellcheck disable=SC1091
source "$MOSEQ_COMMON_DIR/monitor_resources.sh"

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"


moseq_job_init() {
  local stage="$1"
  local project_root="$2"

  if [ -z "$project_root" ]; then
    echo "usage: sbatch $(basename "$0") <project_root> [...]" >&2
    exit 1
  fi
  # Intentionally not `local` -- every stage script's own logic below
  # reads $PROJECT_ROOT afterward, same as before this was factored out.
  PROJECT_ROOT="$(cd "$project_root" && pwd)"

  _JOB_START="$(date -Iseconds)"
  _STATUS_FILE="$PROJECT_ROOT/status/${stage}.json"
  mkdir -p "$PROJECT_ROOT/status"
  _record_status() {
    local rc=$?
    local st; st="$([ "$rc" -eq 0 ] && echo completed || echo failed)"
    printf '{"stage":"%s","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}\n' \
      "$stage" "$st" "$_JOB_START" "$(date -Iseconds)" "$rc" \
      "${SLURMD_NODENAME:-}" "${SLURM_JOB_ID:-}" > "$_STATUS_FILE"
  }
  trap _record_status EXIT

  export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
  export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
  # numexpr (a moseq2-extract dependency) defaults NUMEXPR_MAX_THREADS to
  # 64 and errors ("nthreads cannot be larger than...") if it detects more
  # cores available than that -- illorent's full allocation (256) exceeds
  # it, so every stage needs this set to the job's real allocation.
  export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK
}
