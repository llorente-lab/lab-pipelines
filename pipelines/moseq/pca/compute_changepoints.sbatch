#!/bin/bash
# Useful as the target-duration reference for kappa selection.
#SBATCH --job-name=moseq-changepoints
#SBATCH --partition=illorent
#SBATCH --time=1-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
PCA_FILE_COMPONENTS="${3-}"
PCA_FILE_SCORES="${4-}"
job_init "changepoints" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_changepoints_${SLURM_JOB_ID}.tsv"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"
PCA_FILE_COMPONENTS="${PCA_FILE_COMPONENTS:-$PROJECT_ROOT/_pca/pca.h5}"
PCA_FILE_SCORES="${PCA_FILE_SCORES:-$PROJECT_ROOT/_pca/pca_scores.h5}"

echo "------------------------------------------------------------------"
echo ">>> CHANGEPOINTS START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-pca compute-changepoints \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --pca-file-components "$PCA_FILE_COMPONENTS" \
  --pca-file-scores "$PCA_FILE_SCORES" \
  --cluster-type local \
  --nworkers 1 \
  --cores "$SLURM_CPUS_PER_TASK"

echo "------------------------------------------------------------------"
echo ">>> CHANGEPOINTS END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
