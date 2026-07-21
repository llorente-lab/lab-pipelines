#!/bin/bash
# Scans n_models kappa values, training one model per value. Always
# --cluster-type local (models trained sequentially inside this one job's
# allocation) -- never slurm, same nested-Slurm-from-inside-Apptainer
# reasoning as pca_fit.sbatch. Generous default wall time since n_models
# models fit one after another, not in parallel. --output/--error passed
# by submit_moseq.py as explicit sbatch CLI flags -- see
# submit_moseq.py's _log_flags() docstring for why.
#SBATCH --job-name=moseq-kappa-scan
# Resources come from the registry (moseq/resources.yaml) when submitted via submit_moseq.py.
#SBATCH --partition=illorent
#SBATCH --time=7-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
N_MODELS="${2:-10}"
SCAN_SCALE="${3:-log}"
MIN_KAPPA="${4-}"
MAX_KAPPA="${5-}"
NUM_ITER="${6:-100}"
moseq_job_init "kappa_scan" "$PROJECT_ROOT"

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

# moseq2-model's CLI has no --config-file support at all (confirmed from
# its actual cli.py) -- every parameter here is a plain flag/default,
# nothing comes from config.yaml the way extract/pca do.
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

# Reports/records the best-fitting kappa (see select_best_kappa.py's
# UNCONFIRMED note: this does NOT yet select by median log-likelihood, the
# lab's stated actual convention, only the documented duration/jsd
# objectives -- verify the printed keys the first time this runs for real).
# Deliberately does NOT auto-submit a final learn-model run at this kappa --
# that stays an explicit, separate step.
echo "selecting best-fitting kappa from scan..."
apptainer_python "$MOSEQ_ROOT_DIR/model/select_best_kappa.py" "$PROJECT_ROOT" || \
  echo "select_best_kappa.py failed -- check models/*.p exist and _pca/changepoints.h5 was computed" >&2

echo "==== JOB END: $(date) ===="
