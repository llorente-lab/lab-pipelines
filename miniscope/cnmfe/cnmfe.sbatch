#!/bin/bash
#SBATCH --job-name=cnmfe
# Resources come from the registry (miniscope/resources.yaml) when submitted via `run`.
#SBATCH --partition=illorent
#SBATCH --nodes=1
#SBATCH --time=7-00:00:00
# No --output/--error here: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh,
# sourced automatically via ~/.bashrc) point these at an organized, global
# location under $SCRATCH/logs/cnmfe/ regardless of where this gets
# submitted from. Falls back to Slurm's default (slurm-%j.out in the
# submission directory) if those env vars aren't set for some reason.
#
# Standalone CNMF-E stage. Same three granularities as motion_correction.sbatch:
#
#   sbatch cnmfe.sbatch                    # full sweep
#   sbatch cnmfe.sbatch <mouse>             # everything reconciliation finds for one mouse
#   sbatch cnmfe.sbatch <mouse> <date> <tp> # exactly one session, run directly
#
# Unlike motion_correction.sbatch, this stage has its own internal two-phase
# gate: reconcile_cnmfe.py can discover sessions that need MC (re-)run first
# (entry point 2, mmap missing/expired on scratch). Those get motion-corrected
# and synced BEFORE this script re-checks for newly-ready CNMF-E sessions.
# This is a local gate scoped to this run, not the same thing as the global
# hard gate in master_pipeline.sbatch.

# NOTE: sbatch runs this script from a copied/spooled path, not its real
# location, so BASH_SOURCE-derived paths don't work here. CAIMAN_ROOT points
# at the `current` symlink the deploy agent maintains (see
# deploy/poll_and_deploy.sh) instead.
CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/miniscope}"
source "$CAIMAN_ROOT/common/pipeline_common.sh"

MOUSE="${1-}"
DATE="${2-}"
TP="${3-}"

echo "CNMF-E stage starting: $(date)"

mkdir -p "$SCRATCH/logs/resource_monitor"
start_resource_monitor "$SCRATCH/logs/resource_monitor/cnmfe_${SLURM_JOB_ID}.tsv"

# --- phase 1: satisfy any MC prerequisites this scope needs -----------------

PREREQ_FILE="$LOG_DIR/cnmfe_prereq_${SLURM_JOB_ID}.txt"

if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
  # Single session mode: only enqueue this exact session as an MC prereq if it
  # actually shows up in reconcile_cnmfe's needs-mc list, not unconditionally.
  apptainer_python "$CNMFE_DIR/reconcile_cnmfe.py" --print-needs-mc | grep "^${MOUSE}|${DATE}|${TP}$" > "$PREREQ_FILE" || true
else
  mc_queue "$MOUSE" > "$PREREQ_FILE"
fi

PREREQ_COUNT=$(grep -c . "$PREREQ_FILE" || true)
echo "sessions needing MC before CNMF-E can run: $PREREQ_COUNT"

if [ "$PREREQ_COUNT" -gt 0 ]; then
  while IFS='|' read -r S_MOUSE S_DATE S_TP; do
    [ -z "$S_MOUSE" ] && continue
    echo "prereq MC: $S_MOUSE/$S_DATE/$S_TP"
    run_motion_correction "$S_MOUSE" "$S_DATE" "$S_TP" || echo "prereq MC failed for $S_MOUSE/$S_DATE/$S_TP, its CNMF-E will be skipped below"
  done < "$PREREQ_FILE"
fi
rm -f "$PREREQ_FILE"

# --- phase 2: run CNMF-E on whatever's ready now -----------------------------

SESSIONS_FILE="$LOG_DIR/cnmfe_sessions_${SLURM_JOB_ID}.txt"

if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
  echo "$MOUSE|$DATE|$TP" > "$SESSIONS_FILE"
elif [ -n "$MOUSE" ]; then
  cnmfe_queue "$MOUSE" > "$SESSIONS_FILE"
else
  cnmfe_queue > "$SESSIONS_FILE"
fi

COUNT=$(grep -c . "$SESSIONS_FILE" || true)
echo "sessions ready for CNMF-E: $COUNT"

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
  if ! run_cnmfe "$S_MOUSE" "$S_DATE" "$S_TP"; then
    FAILURES=$((FAILURES + 1))
  fi
done < "$SESSIONS_FILE"

rm -f "$SESSIONS_FILE"

echo ""
echo "CNMF-E stage complete: $(date)"
echo "processed: $SESSION_NUM, failed: $FAILURES"
echo "NOTE: .mmap/.avi were excluded from sync, run a manual sync if you need those off Sherlock"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
