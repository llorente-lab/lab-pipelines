#!/bin/bash
# Runs `rclone copy <source> <project_dir>` on a compute node instead of the
# login node. Drive syncs for real Moseq sessions can be large (many GB of
# depth recordings), and Sherlock login nodes are shared/rate-limited --
# sustained transfers there are exactly the kind of thing that gets you
# throttled or flagged. Submitted by `run moseq pull` via plain `sbatch`
# (not through submit_moseq.py -- this isn't a moseq2 compute stage, just a
# file transfer, so it doesn't need that module's dependency-chaining
# machinery).
#
# Deliberately NOT --exclusive and NOT on the illorent partition, unlike
# every compute stage (extract/pca/model): this is I/O-bound, not
# CPU-bound, so holding any part of the lab's single 256-cpu/1500G
# --exclusive node for a file copy would actively block real compute jobs
# from starting (an --exclusive job needs the WHOLE node free, so even a
# tiny non-exclusive job sitting on illorent delays it). Runs on Sherlock's
# shared `normal` partition instead, using the lab's general SU allocation
# -- modest, fixed resources, since this is just a network transfer.
#
# --output/--error passed as explicit sbatch CLI flags by `run moseq pull`,
# same reasoning as every other stage's _log_flags() -- project_dir isn't
# known until submission time.
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

apptainer_rclone copy "$SOURCE" "$PROJECT_DIR" --progress

echo "------------------------------------------------------------------"
echo ">>> PULL END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
