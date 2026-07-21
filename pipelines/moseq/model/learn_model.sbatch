#!/bin/bash
# Trains a single final model at one chosen kappa value. learn-model has no
# --cluster-type flag at all (confirmed from moseq2-model's actual cli.py)
# -- it's always synchronous/local, so there's no nested-Slurm question
# here regardless of how this job itself was scheduled. --output/--error
# passed by submit_moseq.py as explicit sbatch CLI flags -- see
# submit_moseq.py's _log_flags() docstring for why.
#SBATCH --job-name=moseq-learn-model
# Resources come from the registry (moseq/resources.yaml) when submitted via submit_moseq.py.
#SBATCH --partition=illorent
#SBATCH --time=3-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
KAPPA="${2-}"
NUM_ITER="${3:-1000}"
DEST_NAME="${4:-model.p}"

if [ -z "$KAPPA" ]; then
  echo "usage: sbatch $(basename "$0") <project_root> <kappa> [num_iter] [dest_name]" >&2
  exit 1
fi
job_init "learn_model" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_learn_model_${SLURM_JOB_ID}.tsv"

PCA_SCORES="$PROJECT_ROOT/_pca/pca_scores.h5"
OUTPUT_DIR="$PROJECT_ROOT/models"
INDEX_FILE="$PROJECT_ROOT/moseq2-index.yaml"
mkdir -p "$OUTPUT_DIR"
DEST_FILE="$OUTPUT_DIR/$DEST_NAME"

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
