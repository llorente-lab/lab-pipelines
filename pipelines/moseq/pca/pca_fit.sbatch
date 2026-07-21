#!/bin/bash
# --cluster-type local: Dask uses this job's own allocation; nested Slurm from inside
# Apptainer is not supported.
#SBATCH --job-name=moseq-pca-fit
#SBATCH --partition=illorent
#SBATCH --time=2-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
job_init "pca_fit" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_pca_fit_${SLURM_JOB_ID}.tsv"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

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

# _pca/pca_scree.png is preserved for human review/override.
echo "computing npcs for 90% explained variance..."
apptainer_python "$MOSEQ_ROOT_DIR/pca/compute_npcs.py" "$PROJECT_ROOT" --threshold 90

echo "==== JOB END: $(date) ===="
