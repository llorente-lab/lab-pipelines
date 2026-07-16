#!/bin/bash
# Aggregates every session's proc/ output into aggregate_results/ and
# (re)generates moseq2-index.yaml. Lightweight bookkeeping, not extraction
# itself -- still run as its own job (not on the login node) both for
# Sherlock's login-node usage policy and so it gets its own log file like
# every other stage.
#SBATCH --job-name=moseq_aggregate
#SBATCH --partition=normal
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=00:30:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch aggregate.sbatch <project_root>" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

apptainer_exec moseq2-extract aggregate-results \
  --input-dir "$PROJECT_ROOT" \
  --output-dir "$PROJECT_ROOT/aggregate_results/"

apptainer_exec moseq2-extract generate-index \
  --input-dir "$PROJECT_ROOT/aggregate_results" \
  --output-file "$PROJECT_ROOT/moseq2-index.yaml"
