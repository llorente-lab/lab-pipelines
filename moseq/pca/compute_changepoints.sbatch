#!/bin/bash
# Model-free syllable changepoints from PCA scores. Optional in moseq2's
# own workflow, but useful as the target-duration reference for kappa
# selection later, so it's included in the default chain. Same
# --cluster-type local reasoning as the other PCA-stage jobs.
#SBATCH --job-name=moseq_pca
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=15G
#SBATCH --time=01:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch compute_changepoints.sbatch <project_root> [config_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${2:-$PROJECT_ROOT/config.yaml}"
PCA_FILE_COMPONENTS="${3:-$PROJECT_ROOT/_pca/pca.h5}"
PCA_FILE_SCORES="${4:-$PROJECT_ROOT/_pca/pca_scores.h5}"

apptainer_exec moseq2-pca compute-changepoints \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --pca-file-components "$PCA_FILE_COMPONENTS" \
  --pca-file-scores "$PCA_FILE_SCORES" \
  --cluster-type local \
  --nworkers 1 \
  --cores "${SLURM_CPUS_PER_TASK:-4}"
