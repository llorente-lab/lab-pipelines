#!/bin/bash
# Projects extracted sessions onto an already-fit PCA basis. Same
# --cluster-type local reasoning as pca_fit.sbatch. This is also the job
# that re-runs (cheaply) whenever new sessions are added to an existing
# project -- no PCA refit needed, per moseq2-pca's own fit/apply split.
#SBATCH --job-name=moseq_pca
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=15G
#SBATCH --time=01:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch pca_apply.sbatch <project_root> [config_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${2:-$PROJECT_ROOT/config.yaml}"
PCA_FILE="${3:-$PROJECT_ROOT/_pca/pca.h5}"

apptainer_exec moseq2-pca apply-pca \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --pca-file "$PCA_FILE" \
  --cluster-type local \
  --nworkers 1 \
  --cores "${SLURM_CPUS_PER_TASK:-4}" \
  --overwrite-pca-apply true
