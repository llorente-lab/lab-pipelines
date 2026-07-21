#!/bin/bash
# Shared setup + helper functions sourced by every sbatch script in this
# pipeline. Not directly executable, `source` this from other scripts.
#
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_setup.sh"
# shellcheck disable=SC1091
source "$REPO_COMMON_DIR/monitor_resources.sh"
set -euo pipefail

COMMON_DIR="$CAIMAN_COMMON_DIR"
MC_DIR="$CAIMAN_MC_DIR"
CNMFE_DIR="$CAIMAN_CNMFE_DIR"
LOG_DIR="${SCRATCH}/logs/queue"
mkdir -p "$LOG_DIR"

ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"

# per session actions
run_logged() {
  local mouse="$1" date_val="$2" tp="$3" stage="$4"; shift 4
  local session_dir="$ANALYZED_BASE/$mouse/$date_val/$tp"
  mkdir -p "$session_dir/logs"
  local session_log="$session_dir/logs/${stage}_$(date +%Y%m%d_%H%M%S).log"
  "$@" 2>&1 | tee "$session_log"
}

run_motion_correction() {
  local mouse="$1" date="$2" tp="$3"
  echo "MC - starting $mouse/$date/$tp"
  if ! run_logged "$mouse" "$date" "$tp" motion_correct apptainer_python "$MC_DIR/motion_correct.py" "$mouse" "$date" "$tp"; then
    echo "MC - FAILED $mouse/$date/$tp"
    return 1
  fi
  echo "MC - succeeded $mouse/$date/$tp"

  if ! bash "$COMMON_DIR/sync.sh" "$mouse" "$date" "$tp"; then
    echo "MC - SYNC FAILED $mouse/$date/$tp (motion correction itself succeeded, only the Drive copy failed)"
    return 1
  fi
  return 0
}

run_cnmfe() {
  local mouse="$1" date="$2" tp="$3"
  echo "CNMFE - starting $mouse/$date/$tp"
  if ! run_logged "$mouse" "$date" "$tp" cnmfe apptainer_python "$CNMFE_DIR/cnmfe_modeling.py" "$mouse" "$date" "$tp"; then
    echo "CNMFE - FAILED $mouse/$date/$tp"
    return 1
  fi
  echo "CNMFE - succeeded $mouse/$date/$tp"

  if ! bash "$COMMON_DIR/sync.sh" "$mouse" "$date" "$tp"; then
    echo "CNMFE - SYNC FAILED $mouse/$date/$tp (CNMF-E itself succeeded, only the Drive copy failed)"
    return 1
  fi
  return 0
}

# reconciliation queue helpers
mc_queue() {
  local mouse_filter="${1-}"
  local combined
  combined="$( { apptainer_python "$MC_DIR/reconcile_motion_correction.py" --print-output
                 apptainer_python "$CNMFE_DIR/reconcile_cnmfe.py" --print-needs-mc; } | sort -u )"
  if [ -n "$mouse_filter" ]; then
    echo "$combined" | grep "^${mouse_filter}|" || true
  else
    echo "$combined"
  fi
}

# Prints mouse|date|tp lines ready for CNMF-E, optionally filtered to one mouse.
cnmfe_queue() {
  local mouse_filter="${1-}"
  local ready
  ready="$(apptainer_python "$CNMFE_DIR/reconcile_cnmfe.py" --print-output)"
  if [ -n "$mouse_filter" ]; then
    echo "$ready" | grep "^${mouse_filter}|" || true
  else
    echo "$ready"
  fi
}
