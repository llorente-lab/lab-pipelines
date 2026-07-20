#!/bin/bash
# Fits PCA across the whole aggregated session batch. Always --cluster-type
# local -- Dask uses the cores this job's own allocation was given, no
# nested Slurm submission from inside the container. --output/--error
# passed by submit_moseq.py as explicit sbatch CLI flags -- see
# submit_moseq.py's _log_flags() docstring for why.
#SBATCH --job-name=moseq-pca-fit
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=2-00:00:00
#SBATCH --exclusive

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
moseq_job_init "pca_fit" "$PROJECT_ROOT"
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

# Auto-select npcs at 90% cumulative explained variance and record it into
# config.yaml -- removes the "eyeball the scree plot" hard gate, but
# _pca/pca_scree.png is still there for a human to check/override this if
# it looks wrong.
echo "computing npcs for 90% explained variance..."
apptainer_python "$MOSEQ_ROOT_DIR/pca/compute_npcs.py" "$PROJECT_ROOT" --threshold 90

echo "==== JOB END: $(date) ===="
