#!/bin/bash
# Fits PCA across the whole aggregated session batch. Always --cluster-type
# local -- Dask uses the cores this job's own allocation was given, no
# nested Slurm submission from inside the container. --output/--error
# passed by submit_moseq.py as explicit sbatch CLI flags -- see
# extract_session.sbatch's header comment for why.
#SBATCH --job-name=moseq-pca-fit
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=2-00:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch pca_fit.sbatch <project_root> [config_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${2:-$PROJECT_ROOT/config.yaml}"

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK

echo "------------------------------------------------------------------"
echo ">>> PCA FIT START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "Config  => $CONFIG_FILE"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-pca train-pca \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --cluster-type local \
  --nworkers 1 \
  --cores "$SLURM_CPUS_PER_TASK" \
  --local-processes true \
  --overwrite-pca-train true

echo "------------------------------------------------------------------"
echo ">>> PCA FIT END: $(date)"
echo "------------------------------------------------------------------"

# Auto-select npcs at 90% cumulative explained variance and record it into
# config.yaml -- removes the "eyeball the scree plot" hard gate, but
# _pca/pca_scree.png is still there for a human to check/override this if
# it looks wrong.
echo "computing npcs for 90% explained variance..."
apptainer_python "$MOSEQ_ROOT_DIR/pca/compute_npcs.py" "$PROJECT_ROOT" --threshold 90

echo "==== JOB END: $(date) ===="
