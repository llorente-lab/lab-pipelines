#!/bin/bash
#SBATCH --job-name=moseq-aggregate
#SBATCH --partition=illorent
#SBATCH --time=04:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
job_init "aggregate" "$PROJECT_ROOT"
start_resource_monitor "$PROJECT_ROOT/status/resources_aggregate_${SLURM_JOB_ID}.tsv"

echo "------------------------------------------------------------------"
echo ">>> AGGREGATE START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "------------------------------------------------------------------"

apptainer_exec moseq2-extract aggregate-results \
  --input-dir "$PROJECT_ROOT" \
  --output-dir "$PROJECT_ROOT/aggregate_results/"

apptainer_exec moseq2-extract generate-index \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-file "$PROJECT_ROOT/moseq2-index.yaml"

echo "------------------------------------------------------------------"
echo ">>> AGGREGATE END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
