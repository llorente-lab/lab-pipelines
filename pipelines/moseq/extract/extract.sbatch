#!/bin/bash
# Sequential-loop fallback for extraction (one job, all sessions). Use extract_array.sbatch
# for the preferred job-array variant.
#
#SBATCH --job-name=moseq-extract
#SBATCH --partition=illorent
#SBATCH --time=4-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
job_init "extract" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_extract_${SLURM_JOB_ID}.tsv"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "config file not found: $CONFIG_FILE -- generating one now" >&2
  # --camera-type azure: extraction param defaults are set for an Azure
  # Kinect camera, not moseq2-extract's default (k2/Kinect v2) -- Azure is
  # what this lab actually records with.
  # --camera-type azure: lab records with Azure Kinect, not moseq2-extract's default (Kinect v2).
  apptainer_exec moseq2-extract generate-config --output-file "$CONFIG_FILE" --camera-type azure
fi

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "Config  => $CONFIG_FILE"
echo "------------------------------------------------------------------"

while IFS= read -r SESSION_NAME; do
  [ -z "$SESSION_NAME" ] && continue
  SESSION_DIR="$PROJECT_ROOT/$SESSION_NAME"

  DEPTH_FILE=""
  for ext in dat tar.gz avi mkv; do
    if [ -f "$SESSION_DIR/depth.$ext" ]; then
      DEPTH_FILE="$SESSION_DIR/depth.$ext"
      break
    fi
  done
  if [ -z "$DEPTH_FILE" ]; then
    echo "warning: no depth file in $SESSION_DIR (tried .dat .tar.gz .avi .mkv), skipping" >&2
    continue
  fi

  echo ">>> session: $SESSION_NAME ($DEPTH_FILE)"
  apptainer_exec moseq2-extract extract "$DEPTH_FILE" \
    --config-file "$CONFIG_FILE" \
    --output-dir "$SESSION_DIR/proc" \
    --cluster-type local \
    --skip-completed

done < <(PYTHONPATH="$MOSEQ_COMMON_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -c "
from reconcile_moseq_extraction import sessions_needing_extraction
for s in sessions_needing_extraction('$PROJECT_ROOT'):
    print(s)
")

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
