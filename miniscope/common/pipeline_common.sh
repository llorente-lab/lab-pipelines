#!/bin/bash
# Shared setup + helper functions sourced by every sbatch script in this
# pipeline. Not directly executable, `source` this from other scripts.
#
# Expects these to already be set in the environment (or defaults kick in):
#   SIF              - path to the caiman .sif (default: $GROUP_SCRATCH/containers/caiman_v.01.sif)
#   RCLONE_CONFIG    - path to the shared rclone config
#   SCRATCH          - Sherlock's per-user scratch (set by Sherlock itself)

# This file lives in scripts/common/. Source the interactive-safe env setup
# first (SIF, RCLONE_CONFIG, apptainer_python(), directory vars), THEN turn on
# strict mode -- sbatch jobs should fail loudly on any error, unlike an
# interactive shell.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_setup.sh"
# shellcheck disable=SC1091
source "$CAIMAN_ROOT_DIR/../moseq/common/monitor_resources.sh"
set -euo pipefail

COMMON_DIR="$CAIMAN_COMMON_DIR"
MC_DIR="$CAIMAN_MC_DIR"
CNMFE_DIR="$CAIMAN_CNMFE_DIR"

# Queue files (mc_sessions_*.txt, gate-check files, etc.) span an entire
# sweep of many sessions at once, so those live in the shared, organized log
# tree (see env_setup.sh) rather than inside any one session's directory.
# Per-session run output goes elsewhere, see run_logged() below.
LOG_DIR="${SCRATCH}/logs/queue"
mkdir -p "$LOG_DIR"

ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"

# --- per-session actions -----------------------------------------------------

# Runs a session's script and tees its output into that session's own
# AnalyzedData directory (under logs/), in addition to normal stdout, so a
# whole-sweep SLURM .out file still shows everything live, but each session
# also ends up with a self-contained log next to its mmap/correlation
# image/etc. `set -o pipefail` (already on from above) makes sure a failure
# in the underlying command is still detected even though it's piped into tee.
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

# --- reconciliation queue helpers -------------------------------------------

# Prints mouse|date|tp lines needing MC (both entry points combined), optionally
# filtered to a single mouse if $1 is set. Never fails just because the queue
# is empty (grep with no matches would otherwise trip `set -e`).
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
