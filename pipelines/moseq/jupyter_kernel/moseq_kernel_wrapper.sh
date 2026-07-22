#!/bin/bash
# Jupyter execs this with "-f {connection_file}" appended (see kernel.json).
# We hand that straight through to ipykernel running inside the Moseq
# Apptainer container -- this is the whole trick: the OUTER Jupyter server
# (started by Sherlock OnDemand's Jupyter app) runs on the host/module
# Python as normal, only the actual kernel process executing notebook cells
# runs inside the container. No custom OnDemand app needed, no whole-image
# Jupyter server to babysit -- just standard kernel discovery via
# JUPYTER_PATH (see ../common/env_setup.sh).
#
# MOSEQ_SIF is normally exported by env_setup.sh, and Jupyter kernels
# inherit the server process's environment, so if the OnDemand session's
# shell sourced env_setup.sh before the server started, this picks it up
# with no extra config. But requiring every user to source env_setup.sh
# themselves is exactly what stood between "works for one person who set
# it up" and "registered for everyone" -- so this also falls back to the
# same default env_setup.sh itself uses (see common/env_setup.sh's
# MOSEQ_SIF_OVERRIDE/GROUP_SCRATCH line) if MOSEQ_SIF was never set at
# all. GROUP_SCRATCH is a standard Sherlock-provided env var, not
# something env_setup.sh invents, so this fallback works even for a user
# who has done zero lab-specific setup.
set -euo pipefail

MOSEQ_SIF="${MOSEQ_SIF:-${GROUP_SCRATCH:-/scratch/groups/illorent}/containers/moseq/moseq.sif}"

if [ ! -f "$MOSEQ_SIF" ]; then
  echo "moseq_kernel_wrapper.sh: no container image at MOSEQ_SIF=$MOSEQ_SIF" >&2
  echo "  (falls back to \$GROUP_SCRATCH/containers/moseq/moseq.sif if MOSEQ_SIF isn't set --" >&2
  echo "  see README.md in this directory if that's wrong for your account)" >&2
  exit 1
fi

exec apptainer exec \
  --bind "${SCRATCH:-/tmp},${GROUP_SCRATCH:-/tmp},${GROUP_HOME:-/tmp}" \
  --env "RCLONE_CONFIG=${RCLONE_CONFIG:-}" \
  --env "NUMEXPR_MAX_THREADS=${SLURM_CPUS_PER_TASK:-64}" \
  "$MOSEQ_SIF" \
  python -m ipykernel_launcher "$@"
