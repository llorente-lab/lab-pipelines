#!/bin/bash
#SBATCH --job-name=motion_correction
#SBATCH --partition=illorent
#SBATCH --nodes=1
#SBATCH --time=24:00:00
# No --output/--error: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh) route logs to
# $SCRATCH/logs/motion_correction/. Falls back to slurm-%j.out if those vars aren't set.

# sbatch spools scripts to a temp path, so BASH_SOURCE-derived paths don't work here.
# CAIMAN_ROOT points at the `current` symlink maintained by the deploy agent.
CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/pipelines/miniscope}"
source "$CAIMAN_ROOT/common/pipeline_common.sh"

MOUSE="${1-}"
DATE="${2-}"
TP="${3-}"

export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

echo "motion correction stage starting: $(date)"

mkdir -p "$SCRATCH/logs/resource_monitor"
start_resource_monitor "$SCRATCH/logs/resource_monitor/mc_${SLURM_JOB_ID}.tsv"

SESSIONS_FILE="$LOG_DIR/mc_sessions_${SLURM_JOB_ID}.txt"

if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
  echo "$MOUSE|$DATE|$TP" > "$SESSIONS_FILE"
elif [ -n "$MOUSE" ]; then
  mc_queue "$MOUSE" > "$SESSIONS_FILE"
else
  mc_queue > "$SESSIONS_FILE"
fi

COUNT=$(grep -c . "$SESSIONS_FILE" || true)
echo "sessions to process: $COUNT"

if [ "$COUNT" -eq 0 ]; then
  echo "nothing to do"
  rm -f "$SESSIONS_FILE"
  exit 0
fi

FAILURES=0
SESSION_NUM=0
while IFS='|' read -r S_MOUSE S_DATE S_TP; do
  [ -z "$S_MOUSE" ] && continue
  SESSION_NUM=$((SESSION_NUM + 1))
  echo ""
  echo "[$SESSION_NUM/$COUNT] $S_MOUSE/$S_DATE/$S_TP"
  if ! run_motion_correction "$S_MOUSE" "$S_DATE" "$S_TP"; then
    FAILURES=$((FAILURES + 1))
  fi
done < "$SESSIONS_FILE"

rm -f "$SESSIONS_FILE"

echo ""
echo "motion correction stage complete: $(date)"
echo "processed: $SESSION_NUM, failed: $FAILURES"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
