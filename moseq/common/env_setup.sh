#!/bin/bash
# Interactive-safe environment setup for the Moseq pipeline. Same pattern as
# miniscope/common/env_setup.sh (not set -e, meant to be sourced into an
# ordinary interactive login/salloc/OnDemand shell).
#
# Add this line to ~/.bashrc alongside the miniscope one:
#
#   source $GROUP_HOME/pipelines/current/moseq/common/env_setup.sh
#
# Moseq projects still need one canonical home, same reasoning as
# Miniscope's shared-scratch-for-reconciliation argument: everyone's jobs
# need to see the same on-disk state for `run moseq queue`/reconciliation
# to mean anything. moseq2 itself only requires that a project's session
# folders/config.yaml/aggregate_results/_pca/models all live as siblings
# under one base_dir -- it doesn't care WHERE that base_dir is. So
# $MOSEQ_PROJECTS_BASE/<project_name>/ IS that base_dir, one canonical
# per-project directory, no separate RawData/AnalyzedData split (unlike
# Miniscope): a Moseq project isn't "raw data that gets transformed
# in place then published elsewhere," it's one working tree that
# accumulates config/PCA/model outputs alongside the raw sessions as the
# pipeline progresses, so splitting raw from working would just add a
# copy/symlink step moseq2 doesn't need.
#
# Getting data INTO $MOSEQ_PROJECTS_BASE/<project_name>/ from Drive is a
# deliberately manual step (`run moseq init <name>` does one explicit pull
# at project setup; `run sync` for pulling in newly added sessions later),
# not an automatic per-job pull like Miniscope's motion_correct.py does.
# Decided this way on purpose: unlike Miniscope's fixed RawData/AnalyzedData
# convention, Moseq's Drive-side layout for a given lab member's project
# may not be as uniform, and extraction jobs silently reaching out to Drive
# mid-run adds a failure mode (Drive auth, network, race with an in-flight
# upload) that a single explicit sync step avoids.

MOSEQ_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MOSEQ_ROOT_DIR="$(cd "$MOSEQ_COMMON_DIR/.." && pwd)"
export MOSEQ_COMMON_DIR

# Same cli/ wiring as Miniscope's env_setup.sh -- idempotent, safe if both
# pipelines' env_setup.sh get sourced in the same shell.
CLI_DIR="$(cd "$MOSEQ_ROOT_DIR/../cli" && pwd)"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;  # already on PATH, don't add it twice
  *) export PATH="$CLI_DIR:$PATH" ;;
esac
export MOSEQ_SIF="${MOSEQ_SIF_OVERRIDE:-$GROUP_SCRATCH/containers/moseq/moseq.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

# Canonical home for every lab member's Moseq projects (see comment above).
export MOSEQ_PROJECTS_BASE="${MOSEQ_PROJECTS_BASE:-$GROUP_SCRATCH/Moseq}"
mkdir -p "$MOSEQ_PROJECTS_BASE" 2>/dev/null || true

# Drive-side mirror of the same layout: gdrive:Moseq/<project_name>/ <->
# $MOSEQ_PROJECTS_BASE/<project_name>/, same session subfolder names on
# both sides. `run moseq init`/`run sync` assume this symmetry.
export MOSEQ_DRIVE_BASE="${MOSEQ_DRIVE_BASE:-gdrive:Moseq}"

JUPYTER_KERNEL_DIR="$MOSEQ_ROOT_DIR/jupyter_kernel"
case ":${JUPYTER_PATH:-}:" in
  *":$JUPYTER_KERNEL_DIR:"*) ;;
  *) export JUPYTER_PATH="$JUPYTER_KERNEL_DIR${JUPYTER_PATH:+:$JUPYTER_PATH}" ;;
esac

# Short wrapper, same shape as apptainer_python for Miniscope.
apptainer_python() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" --env "PYTHONNOUSERSITE=1" \
    "$MOSEQ_SIF" python "$@"
}

apptainer_rclone() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" "$MOSEQ_SIF" rclone "$@"
}

# Generic escape hatch for moseq2's own console commands (moseq2-extract,
# moseq2-pca, moseq2-model, ...), which are installed entry points, not raw
# python scripts, so apptainer_python doesn't cover them. Used by the
# extract_session.sbatch/pca_*.sbatch job scripts in extract/ and pca/.
apptainer_exec() {
  apptainer exec --env "RCLONE_CONFIG=${RCLONE_CONFIG}" --env "PYTHONNOUSERSITE=1" \
    "$MOSEQ_SIF" "$@"
}

alias moseq_cd='cd "$MOSEQ_ROOT_DIR"'

echo "moseq env loaded: MOSEQ_SIF=$MOSEQ_SIF, RCLONE_CONFIG=$RCLONE_CONFIG" >&2
