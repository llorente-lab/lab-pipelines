#!/bin/bash
# Job-array variant of extract.sbatch: one array task per session, so each
# session gets its own SLURM job ID, its own log file, and its own status
# entry -- a single session failure doesn't abort the rest.
#
# NOT submitted directly. submit_moseq.py's submit_extraction() writes a
# sessions list to <project_root>/status/extract_sessions.txt, then submits
# this script with --array=0-{n-1} added as a CLI flag so the count matches
# however many sessions actually need extraction at that moment. Each task
# picks its session by indexing into that file using $SLURM_ARRAY_TASK_ID.
#
# --output/--error are also added by submit_moseq.py (not baked in here)
# using the %A-%a format so each task gets its own log:
#   <project_root>/slurm_logs/extract-<array_job_id>-<task_id>.out
#
# Config file generation: if config.yaml doesn't exist yet, the first task
# to run generates it. On illorent (one exclusive node), array tasks queue
# sequentially, so by the time task 1 starts, task 0 has already written the
# config -- no race in practice. If you ever run this on a multi-node setup
# that could co-schedule array tasks, generate config.yaml before submitting.
#
# Backup: extract.sbatch (sequential loop, one job, all sessions) is kept
# as-is and can be submitted directly or via submit_extraction(use_array=False).
#
# See extract.sbatch's header for the --output-dir / batch-extract bug
# that's why we call plain `extract` per session rather than `batch-extract`.
#SBATCH --job-name=moseq-extract
# Resources come from the registry (moseq/resources.yaml) when submitted via submit_moseq.py.
# Each array task is one session: light fan-out jobs, normal partition.
#SBATCH --partition=normal
#SBATCH --time=1-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
SESSIONS_FILE="${2-}"
CONFIG_FILE="${3-}"
moseq_job_init "extract" "$PROJECT_ROOT"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

if [ -z "${SLURM_ARRAY_TASK_ID-}" ]; then
  echo "error: SLURM_ARRAY_TASK_ID is not set -- this script must be submitted as a job array (--array=...)" >&2
  exit 1
fi

if [ -z "$SESSIONS_FILE" ] || [ ! -f "$SESSIONS_FILE" ]; then
  echo "error: sessions file not found: ${SESSIONS_FILE:-(not provided)}" >&2
  echo "       submit via submit_moseq.py's submit_extraction(), not directly" >&2
  exit 1
fi

# Array task index is 0-based; sed line numbers are 1-based.
SESSION_NAME="$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$SESSIONS_FILE")"
if [ -z "$SESSION_NAME" ]; then
  echo "error: no session at index $SLURM_ARRAY_TASK_ID in $SESSIONS_FILE" >&2
  exit 1
fi

# Override the status file written by moseq_job_init's EXIT trap to be
# per-session rather than a single status/extract.json that all tasks would
# race to overwrite. _record_status() resolves _STATUS_FILE at trap-fire
# time (not at definition time), so reassigning it here takes effect.
_STATUS_FILE="$PROJECT_ROOT/status/extract_${SESSION_NAME}.json"
start_resource_monitor "$PROJECT_ROOT/status/resources_extract_${SESSION_NAME}.tsv"

SESSION_DIR="$PROJECT_ROOT/$SESSION_NAME"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "config file not found: $CONFIG_FILE -- generating one now" >&2
  apptainer_exec moseq2-extract generate-config --output-file "$CONFIG_FILE" --camera-type azure
fi

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION START [array task $SLURM_ARRAY_TASK_ID / session: $SESSION_NAME]: $(date)"
echo "Project => $PROJECT_ROOT"
echo "Session => $SESSION_NAME"
echo "Config  => $CONFIG_FILE"
echo "------------------------------------------------------------------"

DEPTH_FILE=""
for ext in dat tar.gz avi mkv; do
  if [ -f "$SESSION_DIR/depth.$ext" ]; then
    DEPTH_FILE="$SESSION_DIR/depth.$ext"
    break
  fi
done
if [ -z "$DEPTH_FILE" ]; then
  echo "error: no depth file in $SESSION_DIR (tried .dat .tar.gz .avi .mkv)" >&2
  exit 1
fi

echo ">>> depth file: $DEPTH_FILE"
apptainer_exec moseq2-extract extract "$DEPTH_FILE" \
  --config-file "$CONFIG_FILE" \
  --output-dir "$SESSION_DIR/proc" \
  --cluster-type local \
  --skip-completed

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION END [array task $SLURM_ARRAY_TASK_ID / session: $SESSION_NAME]: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
