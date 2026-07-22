#!/bin/bash
# Interactive-safe environment setup for the <name> pipeline. Not `set -e` --
# meant to be sourced into an ordinary interactive login/salloc/OnDemand shell
# (as well as non-interactively, e.g. by kernel wrappers or `run`'s own
# startup -- so don't add anything here that assumes an interactive TTY).
#
# Add to ~/.bashrc (setup.sh does this for you automatically once this
# pipeline has a real entry in the repo root's pipelines.yaml):
#   source $GROUP_HOME/pipelines/current/pipelines/<name>/common/env_setup.sh

TEMPLATE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TEMPLATE_ROOT_DIR="$(cd "$TEMPLATE_COMMON_DIR/.." && pwd)"
export TEMPLATE_COMMON_DIR
export REPO_COMMON_DIR="$(cd "$TEMPLATE_ROOT_DIR/../../common" && pwd)"

# Puts `run` on PATH 
CLI_DIR="$(cd "$TEMPLATE_ROOT_DIR/../../cli" && pwd)"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;
  *) export PATH="$CLI_DIR:$PATH" ;;
esac
.
export TEMPLATE_SIF="${TEMPLATE_SIF_OVERRIDE:-$GROUP_SCRATCH/containers/template/template.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

# Wherever this pipeline's projects/sessions/outputs live. This is the
# "required_env_var" pipelines.yaml checks for and `run` gates on (see
# require_pipeline_env in cli/run) -- pick whatever name and default make
# sense for your pipeline's own data model.
export TEMPLATE_PROJECTS_BASE="${TEMPLATE_PROJECTS_BASE:-$GROUP_SCRATCH/Template}"
mkdir -p "$TEMPLATE_PROJECTS_BASE" 2>/dev/null || true

apptainer_exec() {
  apptainer exec \
    --bind "${SCRATCH:-/tmp},${GROUP_SCRATCH:-/tmp},${GROUP_HOME:-/tmp}" \
    "$TEMPLATE_SIF" "$@"
}

apptainer_python() {
  apptainer exec \
    --bind "${SCRATCH:-/tmp},${GROUP_SCRATCH:-/tmp},${GROUP_HOME:-/tmp}" \
    "$TEMPLATE_SIF" python "$@"
}

# rclone only exists inside the container, not on Sherlock's compute nodes --
# needed if any of your stages call `run sync` from inside a submitted job.
apptainer_rclone() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" "$TEMPLATE_SIF" rclone "$@"
}

alias template_cd='cd "$TEMPLATE_ROOT_DIR"'
