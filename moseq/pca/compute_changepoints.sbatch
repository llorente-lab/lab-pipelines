#!/bin/bash
# Model-free syllable changepoints from PCA scores. Optional in moseq2's
# own workflow, but useful as the target-duration reference for kappa
# selection later. Same --cluster-type local reasoning as the other
# PCA-stage jobs. --output/--error passed by submit_moseq.py as explicit
# sbatch CLI flags -- see submit_moseq.py's _log_flags() docstring.
#SBATCH --job-name=moseq-changepoints
# Resources come from the registry (moseq/resources.yaml) when submitted via submit_moseq.py.
#SBATCH --partition=illorent
#SBATCH --time=1-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
PCA_FILE_COMPONENTS="${3-}"
PCA_FILE_SCORES="${4-}"
moseq_job_init "changepoints" "$PROJECT_ROOT"
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
