#!/bin/bash
# Also the job to rerun cheaply when new sessions are added -- no PCA refit needed.
#SBATCH --job-name=moseq-pca-apply
#SBATCH --partition=illorent
#SBATCH --time=1-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
PCA_FILE="${3-}"
job_init "pca_apply" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_pca_apply_${SLURM_JOB_ID}.tsv"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"
PCA_FILE="${PCA_FILE:-$PROJECT_ROOT/_pca/pca.h5}"

echo "------------------------------------------------------------------"
echo ">>> PCA APPLY START: $(date)"
echo "Project  => $PROJECT_ROOT"
echo "Config   => $CONFIG_FILE"
echo "PCA file => $PCA_FILE"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-pca apply-pca \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --pca-file "$PCA_FILE" \
  --cluster-type local \
  --nworkers 1 \
  --cores "$SLURM_CPUS_PER_TASK" \
  --overwrite-pca-apply true

echo "------------------------------------------------------------------"
echo ">>> PCA APPLY END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
