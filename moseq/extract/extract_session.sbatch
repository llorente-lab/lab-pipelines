#!/bin/bash
# One session's extraction. Submitted per-session by submit_moseq.submit_extraction(),
# never invoked with --cluster-type slurm inside the container -- always
# --cluster-type local, using exactly the cores this job's own sbatch
# allocation was given. See submit_moseq.py's module docstring for why.
#SBATCH --job-name=moseq_extract
#SBATCH --partition=normal
#SBATCH --cpus-per-task=1
#SBATCH --mem=6G
#SBATCH --time=03:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

SESSION_DIR="${1-}"
CONFIG_FILE="${2-}"

if [ -z "$SESSION_DIR" ]; then
  echo "usage: sbatch extract_session.sbatch <session_dir> [config_file]" >&2
  exit 1
fi
SESSION_DIR="$(cd "$SESSION_DIR" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$SESSION_DIR")/config.yaml}"
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

# moseq2-extract's `extract` command defaults --output-dir to the relative
# path "proc", resolved against whatever the process's cwd is -- cd into
# the session directory first so that lands inside the session, not
# wherever this job happened to start.
cd "$SESSION_DIR"

DEPTH_FILE=""
for ext in dat tar.gz avi mkv; do
  if [ -f "depth.$ext" ]; then
    DEPTH_FILE="depth.$ext"
    break
  fi
done
if [ -z "$DEPTH_FILE" ]; then
  echo "extract_session.sbatch: no depth file found in $SESSION_DIR (looked for depth.dat/.tar.gz/.avi/.mkv)" >&2
  exit 1
fi

echo "extracting $SESSION_DIR/$DEPTH_FILE (config: $CONFIG_FILE)"
apptainer_exec moseq2-extract extract "$DEPTH_FILE" \
  --config-file "$CONFIG_FILE" \
  --output-dir proc \
  --cluster-type local \
  --skip-completed
