#!/bin/bash
# Job-array variant of extract.sbatch. Not submitted directly --
# submit_moseq.py's submit_extraction() adds --array and --output/--error
# flags at submission time. See extract.sbatch for why we call plain
# `extract` per session rather than `batch-extract`.
#
# Each array task is a BATCH of sessions, not one session -- the array is
# capped at MAX_EXTRACT_ARRAY_SIZE (submit_moseq.py), so a project with
# hundreds of sessions doesn't spawn hundreds of jobs. Sessions within a
# task's batch are processed sequentially, in a loop below.
#
# CONFIG_FILE must already exist -- generating it here would race across
# array tasks starting concurrently. The caller (cli/pipelines/moseq.sh)
# generates it once, before submission.
#SBATCH --job-name=moseq-extract
#SBATCH --partition=normal
#SBATCH --time=1-00:00:00

set -uo pipefail  # not -e: one session's failure shouldn't skip the rest of the batch
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
SESSIONS_FILE="${2-}"
CONFIG_FILE="${3-}"
job_init "extract" "$PROJECT_ROOT"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

# job_init's EXIT trap writes a job-level status.json when this script
# exits -- all array tasks would otherwise race on the same
# status/extract.json. Give each task its own file; per-session records
# still go into the shared history.jsonl below (safe: appends smaller
# than PIPE_BUF are atomic on a POSIX filesystem).
_STATUS_FILE="$PROJECT_ROOT/status/extract_task_${SLURM_ARRAY_TASK_ID:-0}.json"

if [ -z "${SLURM_ARRAY_TASK_ID-}" ]; then
  echo "error: SLURM_ARRAY_TASK_ID is not set -- this script must be submitted as a job array (--array=...)" >&2
  exit 1
fi

if [ -z "$SESSIONS_FILE" ] || [ ! -f "$SESSIONS_FILE" ]; then
  echo "error: sessions file not found: ${SESSIONS_FILE:-(not provided)}" >&2
  echo "       submit via submit_moseq.py's submit_extraction(), not directly" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "error: config file not found: $CONFIG_FILE -- it must be generated before submission" >&2
  exit 1
fi

# This task's line is a space-separated batch of session names.
BATCH_LINE="$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$SESSIONS_FILE")"
if [ -z "$BATCH_LINE" ]; then
  echo "error: no batch at index $SLURM_ARRAY_TASK_ID in $SESSIONS_FILE" >&2
  exit 1
fi
read -ra BATCH_SESSIONS <<< "$BATCH_LINE"

echo "batch task $SLURM_ARRAY_TASK_ID: ${#BATCH_SESSIONS[@]} session(s): ${BATCH_SESSIONS[*]}"

FAILED_SESSIONS=()

for SESSION_NAME in "${BATCH_SESSIONS[@]}"; do
  SESSION_DIR="$PROJECT_ROOT/$SESSION_NAME"

  # job_init's trap only fires once, at task exit, so it can't record each
  # session in the batch -- write a per-session record directly instead.
  START_TIME="$(date -Iseconds)"

  echo "------------------------------------------------------------------"
  echo ">>> EXTRACTION START [array task $SLURM_ARRAY_TASK_ID / session: $SESSION_NAME]: $(date)"
  echo "Project => $PROJECT_ROOT"
  echo "Session => $SESSION_NAME"
  echo "Config  => $CONFIG_FILE"
  echo "------------------------------------------------------------------"

  start_resource_monitor "$PROJECT_ROOT/status/resources_extract_${SESSION_NAME}.tsv"

  DEPTH_FILE=""
  for ext in dat tar.gz avi mkv; do
    if [ -f "$SESSION_DIR/depth.$ext" ]; then
      DEPTH_FILE="$SESSION_DIR/depth.$ext"
      break
    fi
  done

  SESSION_RC=0
  if [ -z "$DEPTH_FILE" ]; then
    echo "error: no depth file in $SESSION_DIR (tried .dat .tar.gz .avi .mkv)" >&2
    SESSION_RC=1
  else
    echo ">>> depth file: $DEPTH_FILE"
    apptainer_exec moseq2-extract extract "$DEPTH_FILE" \
      --config-file "$CONFIG_FILE" \
      --output-dir "$SESSION_DIR/proc" \
      --cluster-type local \
      --skip-completed
    SESSION_RC=$?
  fi

  SESSION_STATUS="$([ "$SESSION_RC" -eq 0 ] && echo completed || echo failed)"
  printf '{"stage":"extract","session":"%s","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}\n' \
    "$SESSION_NAME" "$SESSION_STATUS" "$START_TIME" "$(date -Iseconds)" "$SESSION_RC" \
    "${SLURMD_NODENAME:-}" "${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-}}_${SLURM_ARRAY_TASK_ID:-}" \
    | tee "$PROJECT_ROOT/status/extract_${SESSION_NAME}.json" >> "$PROJECT_ROOT/status/history.jsonl"

  if [ "$SESSION_RC" -ne 0 ]; then
    FAILED_SESSIONS+=("$SESSION_NAME")
  fi

  echo "------------------------------------------------------------------"
  echo ">>> EXTRACTION END [array task $SLURM_ARRAY_TASK_ID / session: $SESSION_NAME]: $(date), status: $SESSION_STATUS"
  echo "------------------------------------------------------------------"
done

if [ "${#FAILED_SESSIONS[@]}" -gt 0 ]; then
  echo "batch task $SLURM_ARRAY_TASK_ID: ${#FAILED_SESSIONS[@]} session(s) failed: ${FAILED_SESSIONS[*]}" >&2
  echo "==== JOB END: $(date) ===="
  exit 1
fi

echo "==== JOB END: $(date) ===="
