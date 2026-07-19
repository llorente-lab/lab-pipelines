#!/bin/bash
# Batch-extracts all unextracted sessions under project_root using
# moseq2-extract's own batch-extract command (which handles session
# discovery and looping internally). --output/--error passed as explicit
# sbatch CLI flags by submit_moseq.py -- see extract_session.sbatch's
# header comment for why.
#SBATCH --job-name=moseq-extract
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=4-00:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"

if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch extract.sbatch <project_root> [config_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "config file not found: $CONFIG_FILE -- run 'run moseq queue <name>' first to generate it" >&2
  exit 1
fi

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "Config  => $CONFIG_FILE"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-extract batch-extract "$PROJECT_ROOT" \
  --config-file "$CONFIG_FILE" \
  --cluster-type local \
  --skip-completed \
  --skip-checks \
  --run-cmd

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
