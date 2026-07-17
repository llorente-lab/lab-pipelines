#!/bin/bash
# One session's extraction. Submitted per-session by submit_moseq.submit_extraction().
# --output/--error deliberately NOT set here as #SBATCH directives -- they're
# passed as explicit sbatch CLI flags by submit_moseq.py (see its
# _log_flags() docstring for why: project_root isn't known until submission
# time, and CLI flags are the only thing guaranteed to beat a stray
# SBATCH_OUTPUT env var per Slurm's own precedence rules).
#
# Always --cluster-type local inside the container, never slurm -- see
# submit_moseq.py's module docstring.
#SBATCH --job-name=moseq-extract
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=1-00:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

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

# Threading: match this job's SLURM allocation so numeric libraries inside
# the container don't over/under-subscribe cores.
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
# numexpr (a moseq2-extract dependency) defaults NUMEXPR_MAX_THREADS to 64
# and errors ("nthreads cannot be larger than...") if it detects more cores
# than that available -- this node's full allocation (256) exceeds it.
export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK

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

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION START: $(date)"
echo "Session => $SESSION_DIR/$DEPTH_FILE"
echo "Config  => $CONFIG_FILE"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-extract extract "$DEPTH_FILE" \
  --config-file "$CONFIG_FILE" \
  --output-dir proc \
  --cluster-type local \
  --skip-completed

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
