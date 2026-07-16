#!/bin/bash
# Interactive-safe environment setup for the Moseq pipeline. Same pattern as
# miniscope/common/env_setup.sh (not set -e, meant to be sourced into an
# ordinary interactive login/salloc/OnDemand shell).
#
# Add this line to ~/.bashrc alongside the miniscope one:
#
#   source $GROUP_HOME/pipelines/current/moseq/common/env_setup.sh
#
# Unlike Miniscope, Moseq project roots are arbitrary user-chosen
# directories (moseq2 expects the notebook/config/index files to live as
# siblings of the session video folders, wherever those happen to be), not
# one canonical path under $GROUP_SCRATCH. So this file does NOT set a
# MOSEQ_RAW_BASE/MOSEQ_ANALYZED_BASE the way env_setup.sh does for
# Miniscope -- every `run moseq` command instead takes an explicit
# --project <path> (or infers from cwd).

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

export MOSEQ_SIF="${MOSEQ_SIF:-$GROUP_SCRATCH/containers/moseq/moseq_v01.sif}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$GROUP_HOME/rclone/rclone.conf}"

# Jupyter discovers kernelspecs via JUPYTER_PATH, looking for
# <dir>/kernels/<name>/kernel.json under each entry -- NOT a bare
# kernel.json directly in <dir> (this tripped us up once already: an
# earlier version had kernel.json sitting directly in jupyter_kernel/,
# which `jupyter kernelspec list` silently ignored, no error, it just
# never showed up). The actual file now lives at
# jupyter_kernel/kernels/moseq2-apptainer/kernel.json, matching that
# convention. Pointing JUPYTER_PATH at the deployed (GitOps-managed)
# jupyter_kernel/ directory means the kernel shows up automatically in
# Sherlock OnDemand's Jupyter app for anyone who has sourced this file, no
# per-user kernel install step, and it updates automatically on every
# deploy since it's read from `current`. See jupyter_kernel/README.md for
# the OnDemand-sourcing caveat (needs to be verified: does OnDemand's
# Jupyter batch job actually read ~/.bashrc before launching the server?).
JUPYTER_KERNEL_DIR="$MOSEQ_ROOT_DIR/jupyter_kernel"
case ":${JUPYTER_PATH:-}:" in
  *":$JUPYTER_KERNEL_DIR:"*) ;;
  *) export JUPYTER_PATH="$JUPYTER_KERNEL_DIR${JUPYTER_PATH:+:$JUPYTER_PATH}" ;;
esac

# Same global per-job-name log directory convention as Miniscope.
export SBATCH_OUTPUT="$SCRATCH/logs/%x/%j.out"
export SBATCH_ERROR="$SCRATCH/logs/%x/%j.err"
mkdir -p "$SCRATCH/logs/moseq_extract" "$SCRATCH/logs/moseq_pca" \
         "$SCRATCH/logs/moseq_model" "$SCRATCH/logs/queue" 2>/dev/null || true

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
