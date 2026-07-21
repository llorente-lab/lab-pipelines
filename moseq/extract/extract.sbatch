#!/bin/bash
# Extracts all unextracted sessions under project_root, one session at a
# time, calling moseq2-extract's plain `extract` command (NOT
# `batch-extract`) with an explicit --output-dir <session>/proc per
# session. Deliberately NOT using `batch-extract --cluster-type local`:
# that command's own CLI (moseq2_extract/cli.py) captures --output-dir via
# click but only ever forwards it into config_data on the `slurm` branch --
# on `cluster_type == "local"` (which is what we always pass, see
# submit_moseq.py's module docstring on why we never nest Slurm inside
# Apptainer), output_dir is silently dropped before calling
# run_local_extract, so it never lands where the caller expects. Confirmed
# real bug in moseq2-extract's CLI, not something fixable from this
# script -- worth a proper upstream fix in the llorente-lab fork someday,
# but the per-session `extract` loop below sidesteps it entirely since
# plain `extract` forwards output_dir correctly with no such branch.
# --output/--error passed as explicit sbatch CLI flags by submit_moseq.py
# (see submit_moseq.py's _log_flags() docstring for why: project_root
# isn't known until submission time, and CLI flags are the only thing
# guaranteed to beat a stray SBATCH_OUTPUT env var per Slurm's own
# precedence rules).
#
# This used to be two scripts -- this one (looping every unextracted
# session in a single job) and a near-identical extract_session.sbatch
# for a single session -- but submit_moseq.py's submit_extraction() only
# ever called this one; extract_session.sbatch was dead code and has been
# removed rather than kept in sync by hand.
#SBATCH --job-name=moseq-extract
# Resources come from the registry (moseq/resources.yaml) when submitted via submit_moseq.py.
#SBATCH --partition=illorent
#SBATCH --time=4-00:00:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"
source "$MOSEQ_COMMON_DIR/template.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"
moseq_job_init "extract" "$PROJECT_ROOT"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "config file not found: $CONFIG_FILE -- generating one now" >&2
  # --camera-type azure: extraction param defaults are set for an Azure
  # Kinect camera, not moseq2-extract's default (k2/Kinect v2) -- Azure is
  # what this lab actually records with.
  apptainer_exec moseq2-extract generate-config --output-file "$CONFIG_FILE" --camera-type azure
fi

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "Config  => $CONFIG_FILE"
echo "------------------------------------------------------------------"

while IFS= read -r SESSION_NAME; do
  [ -z "$SESSION_NAME" ] && continue
  SESSION_DIR="$PROJECT_ROOT/$SESSION_NAME"

  DEPTH_FILE=""
  for ext in dat tar.gz avi mkv; do
    if [ -f "$SESSION_DIR/depth.$ext" ]; then
      DEPTH_FILE="$SESSION_DIR/depth.$ext"
      break
    fi
  done
  if [ -z "$DEPTH_FILE" ]; then
    echo "warning: no depth file in $SESSION_DIR (tried .dat .tar.gz .avi .mkv), skipping" >&2
    continue
  fi

  echo ">>> session: $SESSION_NAME ($DEPTH_FILE)"
  apptainer_exec moseq2-extract extract "$DEPTH_FILE" \
    --config-file "$CONFIG_FILE" \
    --output-dir "$SESSION_DIR/proc" \
    --cluster-type local \
    --skip-completed

done < <(PYTHONPATH="$MOSEQ_COMMON_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -c "
from reconcile_moseq_extraction import sessions_needing_extraction
for s in sessions_needing_extraction('$PROJECT_ROOT'):
    print(s)
")

echo "------------------------------------------------------------------"
echo ">>> EXTRACTION END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
