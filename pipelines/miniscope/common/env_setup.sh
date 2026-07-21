#!/bin/bash
# Interactive-safe environment setup for the caiman pipeline. Not `set -e` --
# meant to be sourced into an ordinary interactive login/salloc shell.
#
# Add to ~/.bashrc:
#   source $GROUP_HOME/pipelines/current/pipelines/miniscope/common/env_setup.sh

CAIMAN_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAIMAN_ROOT_DIR="$(cd "$CAIMAN_COMMON_DIR/.." && pwd)"
export CAIMAN_MC_DIR="$CAIMAN_ROOT_DIR/motion_correction"
export CAIMAN_CNMFE_DIR="$CAIMAN_ROOT_DIR/cnmfe"
export CAIMAN_COMMON_DIR
export REPO_COMMON_DIR="$(cd "$CAIMAN_ROOT_DIR/../../common" && pwd)"

# Puts `run` (repo root's cli/) on PATH so it's deployed/updated the same
# way as everything else, via the `current` symlink.
CLI_DIR="$(cd "$CAIMAN_ROOT_DIR/../../cli" && pwd)"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;
  *) export PATH="$CLI_DIR:$PATH" ;;
esac

# SIF is always recomputed (not `SIF="${SIF:-...}"`) so a stale exported
# value from an old shell/`.bashrc` never silently shadows a real update.
# SIF_OVERRIDE is the intentional escape hatch for pinning one image.
export SIF="${SIF_OVERRIDE:-$GROUP_SCRATCH/containers/caiman/caiman.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

# Defaults to $GROUP_SCRATCH so reconciliation (which checks scratch state
# Drive can't represent) is meaningful lab-wide, not per-user. Set
# MINISCOPE_STORAGE_TIER=personal for private/exploratory work that
# shouldn't be visible to everyone else's reconciliation.
export MINISCOPE_STORAGE_TIER="${MINISCOPE_STORAGE_TIER:-group}"
if [ "$MINISCOPE_STORAGE_TIER" = "group" ]; then
  export MINISCOPE_RAW_BASE="${MINISCOPE_RAW_BASE:-$GROUP_SCRATCH/Miniscope/RawData}"
  export MINISCOPE_ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$GROUP_SCRATCH/Miniscope/AnalyzedData}"
else
  export MINISCOPE_RAW_BASE="${MINISCOPE_RAW_BASE:-$SCRATCH/Miniscope/RawData}"
  export MINISCOPE_ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"
fi

# One organized place for every job's .out/.err, regardless of where sbatch
# is invoked from. SBATCH_OUTPUT/SBATCH_ERROR are real Slurm env vars read
# at submission time, so $SCRATCH and %x/%j expand correctly (unlike inside
# a #SBATCH comment, which sbatch never shell-expands).
export SBATCH_OUTPUT="$SCRATCH/logs/%x/%j.out"
export SBATCH_ERROR="$SCRATCH/logs/%x/%j.err"

mkdir -p "$SCRATCH/logs/motion_correction" "$SCRATCH/logs/cnmfe" \
         "$SCRATCH/logs/caiman_full_pipeline" "$SCRATCH/logs/caiman_pipeline_test" \
         "$SCRATCH/logs/multisession_registration" \
         "$SCRATCH/logs/queue" 2>/dev/null || true

apptainer_python() {
  local env_args=(--env "RCLONE_CONFIG=${RCLONE_CONFIG}" --env "PYTHONNOUSERSITE=1")
  if [ -n "${MINISCOPE_DRIVE_PREFIX-}" ] || [ "${MINISCOPE_DRIVE_PREFIX-unset}" = "" ]; then
    env_args+=(--env "MINISCOPE_DRIVE_PREFIX=${MINISCOPE_DRIVE_PREFIX}")
  fi
  apptainer exec "${env_args[@]}" "$SIF" python "$@"
}

# rclone only exists inside the container, not on Sherlock's compute nodes.
apptainer_rclone() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" "$SIF" rclone "$@"
}

alias caiman_cd='cd "$CAIMAN_ROOT_DIR"'

#echo "caiman env loaded: SIF=$SIF, RCLONE_CONFIG=$RCLONE_CONFIG, storage_tier=$MINISCOPE_STORAGE_TIER ($MINISCOPE_ANALYZED_BASE)" >&2
