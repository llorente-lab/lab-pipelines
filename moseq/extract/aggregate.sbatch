#!/bin/bash
# Aggregates every session's proc/ output into aggregate_results/ and
# (re)generates moseq2-index.yaml. --output/--error passed by
# submit_moseq.py as explicit sbatch CLI flags, not set here -- see
# submit_moseq.py's _log_flags() docstring for why.
#SBATCH --job-name=moseq-aggregate
# Resources come from the registry (moseq/resources.yaml) when submitted via submit_moseq.py.
#SBATCH --partition=illorent
#SBATCH --time=04:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
moseq_job_init "aggregate" "$PROJECT_ROOT"

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
