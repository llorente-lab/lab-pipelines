#!/bin/bash
# Interactive-safe environment setup for the caiman pipeline.
#
# Unlike pipeline_common.sh, this does NOT set -e, it's meant to be sourced
# into an ordinary interactive login/salloc shell, where a single failed
# command should not silently kill your terminal session.
#
# Add this line to ~/.bashrc so every new shell has it automatically, no more
# re-exporting SIF/RCLONE_CONFIG by hand each time:
#
#   source ~/pipelines/current/miniscope/common/env_setup.sh
#
# ~/pipelines/current is a symlink maintained by deploy/poll_and_deploy.sh
# (see the repo root), always pointing at the latest deployed commit -- this
# line never needs to change even as new versions get deployed underneath it.

# This file lives in miniscope/common/. Resolve sibling directories relative
# to it so it works no matter where the pipeline root actually lives on disk.
CAIMAN_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAIMAN_ROOT_DIR="$(cd "$CAIMAN_COMMON_DIR/.." && pwd)"
export CAIMAN_MC_DIR="$CAIMAN_ROOT_DIR/motion_correction"
export CAIMAN_CNMFE_DIR="$CAIMAN_ROOT_DIR/cnmfe"
export CAIMAN_COMMON_DIR

export SIF="${SIF:-$GROUP_SCRATCH/containers/caiman/caiman_v.01.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

# One global, organized place for every SLURM .out/.err file, regardless of
# where `sbatch` happens to be run from. %x is the job name, %j the job ID,
# so each stage's job logs land in their own subfolder:
#   $SCRATCH/logs/motion_correction/<jobid>.out
#   $SCRATCH/logs/cnmfe/<jobid>.out
#   $SCRATCH/logs/caiman_master/<jobid>.out
#   $SCRATCH/logs/caiman_pipeline_test/<jobid>.out
# SBATCH_OUTPUT/SBATCH_ERROR are real Slurm-recognized environment variables
# (sbatch reads them at submission time) that override the #SBATCH
# --output/--error lines baked into each .sbatch file. Since this is a plain
# env var, $SCRATCH and %x/%j both resolve correctly, unlike putting them
# directly in a #SBATCH comment, which sbatch does not shell-expand.
export SBATCH_OUTPUT="$SCRATCH/logs/%x/%j.out"
export SBATCH_ERROR="$SCRATCH/logs/%x/%j.err"

# Slurm won't create these directories itself -- job names as of this
# pipeline: motion_correction, cnmfe, caiman_master, caiman_pipeline_test.
mkdir -p "$SCRATCH/logs/motion_correction" "$SCRATCH/logs/cnmfe" \
         "$SCRATCH/logs/caiman_master" "$SCRATCH/logs/caiman_pipeline_test" \
         "$SCRATCH/logs/queue" 2>/dev/null || true

# Short wrapper: `apptainer_python foo.py args...` instead of the full
# apptainer exec --env ... --env ... $SIF python foo.py args... every time.
apptainer_python() {
  local env_args=(--env "RCLONE_CONFIG=${RCLONE_CONFIG}" --env "PYTHONNOUSERSITE=1")
  if [ -n "${MINISCOPE_DRIVE_PREFIX-}" ] || [ "${MINISCOPE_DRIVE_PREFIX-unset}" = "" ]; then
    env_args+=(--env "MINISCOPE_DRIVE_PREFIX=${MINISCOPE_DRIVE_PREFIX}")
  fi
  apptainer exec "${env_args[@]}" "$SIF" python "$@"
}

# rclone isn't installed on Sherlock's compute nodes, only inside the
# container (per the Dockerfile). Any script that shells out to `rclone`
# directly (sync.sh) needs to go through this instead of calling the bare
# `rclone` command, or it fails with "rclone: command not found".
apptainer_rclone() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" "$SIF" rclone "$@"
}

# Quick jump to the scripts root.
alias caiman_cd='cd "$CAIMAN_ROOT_DIR"'

echo "caiman env loaded: SIF=$SIF, RCLONE_CONFIG=$RCLONE_CONFIG" >&2
