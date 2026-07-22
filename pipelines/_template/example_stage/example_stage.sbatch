#!/bin/bash
# Minimal example stage script -- copy this shape for each real stage your
# pipeline needs. The three things every stage script should do, in order:
#   1. source env_setup.sh (for TEMPLATE_SIF, apptainer_exec, etc.)
#   2. source job_template.sh and call job_init -- this is what gives you
#      status/<stage>.json + status/history.jsonl (and the dashboard, by
#      extension) for free, no extra code.
#   3. start_resource_monitor, then do the actual work.
#
#SBATCH --job-name=template-example-stage
#SBATCH --partition=normal
#SBATCH --time=01:00:00
# cores/mem/partition above are just #SBATCH fallbacks -- cli/resources.sh's
# _apply_resource_overrides (bash submission) or
# estimate_resources.resource_flags() (Python submission) will pass explicit
# --partition/--cpus-per-task/--mem flags at submit time that take precedence
# over these, driven by resources.yaml. Keep these as sane defaults for
# someone who runs `sbatch example_stage.sbatch` directly without going
# through `run`.

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/<name>/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

# First positional arg is whatever your pipeline calls its "scope" --
# a project root (MoSeq-style) or something you build from mouse/date/tp
# (Miniscope-style). job_init's second argument is used to resolve
# status/<stage>.json and status/history.jsonl underneath it.
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
