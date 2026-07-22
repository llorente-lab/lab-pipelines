#!/bin/bash
# Minimal example stage script -- copy this shape for each real stage.
# Every stage script should, in order:
#   1. source env_setup.sh
#   2. source job_template.sh and call job_init -- gives you
#      status/<stage>.json + status/history.jsonl (and the dashboard) for
#      free, no extra code.
#   3. start_resource_monitor, then do the actual work.
#
#SBATCH --job-name=template-example-stage
#SBATCH --partition=normal
#SBATCH --time=01:00:00
# cores/mem/partition above are just fallbacks for a direct `sbatch` call --
# resources.yaml drives the real --partition/--cpus-per-task/--mem flags
# `run` passes at submit time, which take precedence.

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/<name>/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

# First positional arg is this pipeline's "scope" -- a project root
# (MoSeq-style) or something built from mouse/date/tp (Miniscope-style).
SCOPE_DIR="${1-}"
job_init "example-stage" "$SCOPE_DIR"

start_resource_monitor "$SCOPE_DIR/status/resources_example-stage_${SLURM_JOB_ID}.tsv"

echo "------------------------------------------------------------------"
echo ">>> EXAMPLE STAGE START: $(date)"
echo "Scope => $SCOPE_DIR"
echo "------------------------------------------------------------------"

apptainer_exec echo "replace this with a real command, e.g. your pipeline's CLI"

echo "------------------------------------------------------------------"
echo ">>> EXAMPLE STAGE END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
