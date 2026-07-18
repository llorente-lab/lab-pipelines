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
#   source $GROUP_HOME/pipelines/current/miniscope/common/env_setup.sh
#
# $GROUP_HOME/pipelines/current is a symlink maintained by
# deploy/poll_and_deploy.sh (see the repo root), shared across the whole lab
# and always pointing at the latest deployed commit -- this line never needs
# to change even as new versions get deployed underneath it, and it's the
# same for every lab member, not just whoever originally set this up.

# This file lives in miniscope/common/. Resolve sibling directories relative
# to it so it works no matter where the pipeline root actually lives on disk.
CAIMAN_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAIMAN_ROOT_DIR="$(cd "$CAIMAN_COMMON_DIR/.." && pwd)"
export CAIMAN_MC_DIR="$CAIMAN_ROOT_DIR/motion_correction"
export CAIMAN_CNMFE_DIR="$CAIMAN_ROOT_DIR/cnmfe"
export CAIMAN_COMMON_DIR

# `run` (the user-facing CLI, see cli/README.md) lives one level up from
# miniscope/ at the repo root's cli/. Adding it to PATH here means it's
# deployed and updated the exact same way as everything else -- through the
# `current` symlink -- with no separate install step.
CLI_DIR="$(cd "$CAIMAN_ROOT_DIR/../cli" && pwd)"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;  # already on PATH, don't add it twice
  *) export PATH="$CLI_DIR:$PATH" ;;
esac

# Non-versioned filename on purpose: GHCR keeps every real version (each CI
# build is tagged with its commit SHA), but Sherlock only ever has one
# on-disk copy at a time -- updating means `apptainer pull` overwriting this
# exact path, no env_setup.sh edit needed.
#
# Deliberately NOT `SIF="${SIF:-...}"` -- see moseq/common/env_setup.sh's
# longer comment on why: that pattern silently stops picking up changes to
# the default the moment SIF is already exported from anywhere (an old
# shell, a stale ~/.bashrc line, a prior sourcing of this same file), with
# no error. SIF is always unconditionally recomputed here; SIF_OVERRIDE is
# the intentional escape hatch for pinning a specific image for one shell.
export SIF="${SIF_OVERRIDE:-$GROUP_SCRATCH/containers/caiman/caiman.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

# Where RawData/AnalyzedData actually get staged during a run. Defaults to
# $GROUP_SCRATCH, not personal $SCRATCH: reconciliation (reconcile_common.py)
# checks scratch for state Drive can't represent (mmap presence, zip
# presence-on-scratch), and that check is only meaningful lab-wide if
# everyone's jobs are staging into the SAME scratch. With personal-scratch
# defaults, two lab members could independently pull and motion-correct the
# same session into their own separate scratch, invisible to each other's
# reconciliation -- duplicated compute and duplicated storage, defeating the
# point of reconciliation. Override to "personal" for genuinely exploratory/
# private work (the tests/_pipeline_test sandbox, a manual reprocess you want
# to inspect before it's official) where that shared-visibility isn't wanted.
export MINISCOPE_STORAGE_TIER="${MINISCOPE_STORAGE_TIER:-group}"
if [ "$MINISCOPE_STORAGE_TIER" = "group" ]; then
  export MINISCOPE_RAW_BASE="${MINISCOPE_RAW_BASE:-$GROUP_SCRATCH/Miniscope/RawData}"
  export MINISCOPE_ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$GROUP_SCRATCH/Miniscope/AnalyzedData}"
else
  export MINISCOPE_RAW_BASE="${MINISCOPE_RAW_BASE:-$SCRATCH/Miniscope/RawData}"
  export MINISCOPE_ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"
fi

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
# pipeline: motion_correction, cnmfe, caiman_master, caiman_pipeline_test,
# miniscope_multisession.
mkdir -p "$SCRATCH/logs/motion_correction" "$SCRATCH/logs/cnmfe" \
         "$SCRATCH/logs/caiman_master" "$SCRATCH/logs/caiman_pipeline_test" \
         "$SCRATCH/logs/miniscope_multisession" \
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

echo "caiman env loaded: SIF=$SIF, RCLONE_CONFIG=$RCLONE_CONFIG, storage_tier=$MINISCOPE_STORAGE_TIER ($MINISCOPE_ANALYZED_BASE)" >&2
