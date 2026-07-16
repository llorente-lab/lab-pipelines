#!/bin/bash
# Fits PCA across the whole aggregated session batch. Always --cluster-type
# local -- Dask uses the cores this job's own allocation was given, no
# nested Slurm submission from inside the container. See
# submit_moseq.py's module docstring for why (elastic multi-node PCA via
# dask-jobqueue's real slurm cluster type is deferred, not attempted yet).
#SBATCH --job-name=moseq_pca
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=20G
#SBATCH --time=02:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch pca_fit.sbatch <project_root> [config_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${2:-$PROJECT_ROOT/config.yaml}"

apptainer_exec moseq2-pca train-pca \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-dir "$PROJECT_ROOT/_pca" \
  --config-file "$CONFIG_FILE" \
  --cluster-type local \
  --nworkers 1 \
  --cores "${SLURM_CPUS_PER_TASK:-4}" \
  --local-processes true \
  --overwrite-pca-train true
