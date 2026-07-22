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
# MOSEQ_SIF must be set in the environment this script runs in. It's
# exported by env_setup.sh, and Jupyter kernels normally inherit the
# server process's environment, so as long as the OnDemand session's shell
# sourced env_setup.sh (via ~/.bashrc) before the server started, this
# picks it up with no extra config. If MOSEQ_SIF ever comes back empty here,
# that's the thing to check first -- see README.md in this directory.
set -euo pipefail

if [ -z "${MOSEQ_SIF-}" ]; then
  echo "moseq_kernel_wrapper.sh: MOSEQ_SIF is not set -- has env_setup.sh been sourced?" >&2
  exit 1
fi

exec apptainer exec \
  --bind "${SCRATCH:-/tmp},${GROUP_SCRATCH:-/tmp},${GROUP_HOME:-/tmp}" \
  --env "RCLONE_CONFIG=${RCLONE_CONFIG:-}" \
  --env "NUMEXPR_MAX_THREADS=${SLURM_CPUS_PER_TASK:-64}" \
  "$MOSEQ_SIF" \
  python -m ipykernel_launcher "$@"
