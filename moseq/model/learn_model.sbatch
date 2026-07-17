#!/bin/bash
# Trains a single final model at one chosen kappa value. learn-model has no
# --cluster-type flag at all (confirmed from moseq2-model's actual cli.py)
# -- it's always synchronous/local, so there's no nested-Slurm question
# here regardless of how this job itself was scheduled. --output/--error
# passed by submit_moseq.py as explicit sbatch CLI flags -- see
# extract_session.sbatch's header comment for why.
#SBATCH --job-name=moseq-learn-model
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=3-00:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
KAPPA="${2-}"
NUM_ITER="${3:-1000}"
DEST_NAME="${4:-model.p}"

if [ -z "$PROJECT_ROOT" ] || [ -z "$KAPPA" ]; then
  echo "usage: sbatch learn_model.sbatch <project_root> <kappa> [num_iter] [dest_name]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

PCA_SCORES="$PROJECT_ROOT/_pca/pca_scores.h5"
OUTPUT_DIR="$PROJECT_ROOT/models"
INDEX_FILE="$PROJECT_ROOT/moseq2-index.yaml"
mkdir -p "$OUTPUT_DIR"
DEST_FILE="$OUTPUT_DIR/$DEST_NAME"

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK

echo "------------------------------------------------------------------"
echo ">>> LEARN MODEL START: $(date)"
echo "PC file => $PCA_SCORES"
echo "Dest    => $DEST_FILE"
echo "Kappa   => $KAPPA | Iterations => $NUM_ITER"
echo "------------------------------------------------------------------"

ARGS=(learn-model "$PCA_SCORES" "$DEST_FILE" \
  --kappa "$KAPPA" --num-iter "$NUM_ITER" --checkpoint-freq 50)
[ -f "$INDEX_FILE" ] && ARGS+=(--index "$INDEX_FILE")

apptainer_exec moseq2-model "${ARGS[@]}"

echo "------------------------------------------------------------------"
echo ">>> LEARN MODEL END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
