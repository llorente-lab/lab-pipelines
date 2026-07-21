#!/bin/bash
# Runs rclone on a compute node. NOT on illorent: this is I/O-bound, and even a small
# non-exclusive job on illorent blocks --exclusive compute jobs from starting (--exclusive
# requires the whole node free). normal partition uses the shared SU allocation instead.
#SBATCH --job-name=moseq-pull
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=04:00:00

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"

SOURCE="${1-}"
PROJECT_DIR="${2-}"

if [ -z "$SOURCE" ] || [ -z "$PROJECT_DIR" ]; then
  echo "usage: sbatch pull.sbatch <source> <project_dir>" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

echo "------------------------------------------------------------------"
echo ">>> PULL START: $(date)"
echo "Source => $SOURCE"
echo "Dest   => $PROJECT_DIR"
echo "------------------------------------------------------------------"

# Delegates to `run sync` (cli/run's generic rclone-copy command) instead of
# calling apptainer_rclone directly -- one implementation of "copy src to
# dst via rclone", shared with miniscope's sync.sh.
run sync "$SOURCE" "$PROJECT_DIR"

echo "------------------------------------------------------------------"
echo ">>> PULL END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
