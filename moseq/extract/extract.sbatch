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
# -- see extract_session.sbatch's header comment for why.
#SBATCH --job-name=moseq-extract
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=256
#SBATCH --mem=1500G
#SBATCH --time=4-00:00:00
#SBATCH --exclusive

echo "==== JOB START: $(date) ===="
echo "Node: $SLURMD_NODENAME"
echo "Cores: $SLURM_CPUS_PER_TASK | Mem: $SLURM_MEM_PER_NODE MB"

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/moseq/common/env_setup.sh"

PROJECT_ROOT="${1-}"
CONFIG_FILE="${2-}"

if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: sbatch extract.sbatch <project_root> [config_file]" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

_JOB_START="$(date -Iseconds)"
_STATUS_FILE="$PROJECT_ROOT/status/extract.json"
mkdir -p "$PROJECT_ROOT/status"
_record_status() {
  local rc=$?
  local st; st="$([ "$rc" -eq 0 ] && echo completed || echo failed)"
  printf '{"stage":"extract","status":"%s","start_time":"%s","end_time":"%s","exit_code":%d,"node":"%s","job_id":"%s"}\n' \
    "$st" "$_JOB_START" "$(date -Iseconds)" "$rc" \
    "${SLURMD_NODENAME:-}" "${SLURM_JOB_ID:-}" > "$_STATUS_FILE"
}
trap _record_status EXIT

if [ ! -f "$CONFIG_FILE" ]; then
  echo "config file not found: $CONFIG_FILE -- generating a default one (same as 'run moseq queue <name>' does)" >&2
  apptainer_exec moseq2-extract generate-config --output-file "$CONFIG_FILE"
fi

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMBA_NUM_THREADS=$SLURM_CPUS_PER_TASK
export VECLIB_MAXIMUM_THREADS=$SLURM_CPUS_PER_TASK
export NUMEXPR_MAX_THREADS=$SLURM_CPUS_PER_TASK

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
