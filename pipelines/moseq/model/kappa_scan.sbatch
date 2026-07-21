#!/bin/bash
# Models are trained sequentially (--cluster-type local), not in parallel -- wall time
# scales with n_models. 2 days is the account's max; split into fewer models if needed.
#SBATCH --job-name=moseq-kappa-scan
#SBATCH --partition=illorent
#SBATCH --time=2-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
N_MODELS="${2:-10}"
SCAN_SCALE="${3:-log}"
MIN_KAPPA="${4-}"
MAX_KAPPA="${5-}"
NUM_ITER="${6:-100}"
job_init "kappa_scan" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_kappa_scan_${SLURM_JOB_ID}.tsv"

PCA_SCORES="$PROJECT_ROOT/_pca/pca_scores.h5"
OUTPUT_DIR="$PROJECT_ROOT/models"
INDEX_FILE="$PROJECT_ROOT/moseq2-index.yaml"
mkdir -p "$OUTPUT_DIR"

echo "------------------------------------------------------------------"
echo ">>> KAPPA SCAN START: $(date)"
echo "PC file => $PCA_SCORES"
echo "Index   => $INDEX_FILE"
echo "Outdir  => $OUTPUT_DIR"
echo "N models=> $N_MODELS ($SCAN_SCALE scale)"
echo "------------------------------------------------------------------"

# moseq2-model has no --config-file support (confirmed from cli.py) -- all params are flags.
ARGS=(kappa-scan "$PCA_SCORES" "$OUTPUT_DIR" \
  --cluster-type local --run-cmd \
  --n-models "$N_MODELS" \
  --scan-scale "$SCAN_SCALE" \
  --num-iter "$NUM_ITER")
[ -f "$INDEX_FILE" ] && ARGS+=(--index "$INDEX_FILE")
[ -n "$MIN_KAPPA" ] && ARGS+=(--min-kappa "$MIN_KAPPA")
[ -n "$MAX_KAPPA" ] && ARGS+=(--max-kappa "$MAX_KAPPA")

apptainer_exec moseq2-model "${ARGS[@]}"

echo "------------------------------------------------------------------"
echo ">>> KAPPA SCAN END: $(date)"
echo "------------------------------------------------------------------"

# NOTE: select_best_kappa.py selects by duration/jsd objectives, NOT median log-likelihood
# (the lab's stated convention) -- verify the printed keys the first time this runs for real.
echo "selecting best-fitting kappa from scan..."
apptainer_python "$MOSEQ_ROOT_DIR/model/select_best_kappa.py" "$PROJECT_ROOT" || \
  echo "select_best_kappa.py failed -- check models/*.p exist and _pca/changepoints.h5 was computed" >&2

echo "==== JOB END: $(date) ===="
