#!/bin/bash
# Projects extracted sessions onto an already-fit PCA basis. Same
# --cluster-type local reasoning as pca_fit.sbatch. Also the job to
# (re)run, cheaply, whenever new sessions are added to an existing project
# -- no PCA refit needed. --output/--error passed by submit_moseq.py as
# explicit sbatch CLI flags -- see submit_moseq.py's _log_flags() docstring.
#SBATCH --job-name=moseq-pca-apply
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=1-00:00:00
#SBATCH --exclusive

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
PCA_FILE="${3-}"
moseq_job_init "pca_apply" "$PROJECT_ROOT"
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
