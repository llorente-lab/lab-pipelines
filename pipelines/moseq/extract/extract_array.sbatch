#!/bin/bash
# Job-array variant of extract.sbatch. Not submitted directly -- submit_moseq.py adds
# --array and --output/--error flags at submission time. See extract.sbatch for why we
# call plain `extract` per session rather than `batch-extract`.
#SBATCH --job-name=moseq-extract
#SBATCH --partition=normal
#SBATCH --time=1-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
SESSIONS_FILE="${2-}"
CONFIG_FILE="${3-}"
job_init "extract" "$PROJECT_ROOT"
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

SESSION_NAME="$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$SESSIONS_FILE")"
if [ -z "$SESSION_NAME" ]; then
  echo "error: no session at index $SLURM_ARRAY_TASK_ID in $SESSIONS_FILE" >&2
  exit 1
fi

# Per-session status file -- all array tasks would race to overwrite a shared status/extract.json.
# _record_status() resolves _STATUS_FILE at trap-fire time, so reassigning here takes effect.
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
