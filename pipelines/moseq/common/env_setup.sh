#!/bin/bash
# Interactive-safe environment setup for the Moseq pipeline. Not `set -e` --
# meant to be sourced into an ordinary interactive login/salloc/OnDemand shell.
#
# Add to ~/.bashrc:
#   source $GROUP_HOME/pipelines/current/pipelines/moseq/common/env_setup.sh
#

MOSEQ_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MOSEQ_ROOT_DIR="$(cd "$MOSEQ_COMMON_DIR/.." && pwd)"
export MOSEQ_COMMON_DIR
export REPO_COMMON_DIR="$(cd "$MOSEQ_ROOT_DIR/../../common" && pwd)"

# Puts `run` on PATH, same as miniscope's env_setup.sh -- idempotent, safe
# if both pipelines' env_setup.sh are sourced in the same shell.
CLI_DIR="$(cd "$MOSEQ_ROOT_DIR/../../cli" && pwd)"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;
  *) export PATH="$CLI_DIR:$PATH" ;;
esac
export MOSEQ_SIF="${MOSEQ_SIF_OVERRIDE:-$GROUP_SCRATCH/containers/moseq/moseq.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

export MOSEQ_PROJECTS_BASE="${MOSEQ_PROJECTS_BASE:-$GROUP_SCRATCH/Moseq}"
mkdir -p "$MOSEQ_PROJECTS_BASE" 2>/dev/null || true

# Drive mirror: gdrive:Moseq/<project_name>/ <-> $MOSEQ_PROJECTS_BASE/<project_name>/
export MOSEQ_DRIVE_BASE="${MOSEQ_DRIVE_BASE:-gdrive:Moseq}"

JUPYTER_KERNEL_DIR="$MOSEQ_ROOT_DIR/jupyter_kernel"
case ":${JUPYTER_PATH:-}:" in
  *":$JUPYTER_KERNEL_DIR:"*) ;;
  *) export JUPYTER_PATH="$JUPYTER_KERNEL_DIR${JUPYTER_PATH:+:$JUPYTER_PATH}" ;;
esac

apptainer_python() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" --env "PYTHONNOUSERSITE=1" \
    "$MOSEQ_SIF" python "$@"
}

apptainer_rclone() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" "$MOSEQ_SIF" rclone "$@"
}

# Escape hatch for moseq2's own console commands (moseq2-extract, moseq2-pca,
# moseq2-model, ...), which are installed entry points, not raw scripts.
apptainer_exec() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" --env "PYTHONNOUSERSITE=1" \
    "$MOSEQ_SIF" "$@"
}

# Dev-testing escape hatch: runs against the real container (same compiled
# ABI as production) but binds $MOSEQ_DEV_DIR's editable package checkouts
# in first on PYTHONPATH, so Python imports locally edited source instead of
# the copy baked into the image. See pipelines/moseq/README.md.
export MOSEQ_DEV_DIR="${MOSEQ_DEV_DIR:-$HOME/moseq-dev}"

apptainer_dev_exec() {
  local dev_pythonpath=""
  local pkg
  for pkg in moseq2-pca moseq2-model moseq2-viz moseq2-extract moseq2-app \
             pyhsmm-autoregressive pyhsmm pybasicbayes; do
    if [ -d "$MOSEQ_DEV_DIR/$pkg" ]; then
      dev_pythonpath="${dev_pythonpath:+$dev_pythonpath:}/moseq-dev/$pkg"
    fi
  done
  if [ -z "$dev_pythonpath" ]; then
    echo "apptainer_dev_exec: no editable checkouts found under $MOSEQ_DEV_DIR -- falling back to the container's own packages" >&2
  fi
  apptainer exec \
    --bind "${SCRATCH:-/tmp},${GROUP_SCRATCH:-/tmp},${GROUP_HOME:-/tmp}" \
    --bind "$MOSEQ_DEV_DIR:/moseq-dev" \
    --env "RCLONE_CONFIG=${RCLONE_CONFIG}" \
    --env "PYTHONNOUSERSITE=1" \
    --env "PYTHONPATH=${dev_pythonpath}" \
    "$MOSEQ_SIF" "$@"
}

alias moseq_cd='cd "$MOSEQ_ROOT_DIR"'

#echo "moseq env loaded: MOSEQ_SIF=$MOSEQ_SIF, RCLONE_CONFIG=$RCLONE_CONFIG" >&2
