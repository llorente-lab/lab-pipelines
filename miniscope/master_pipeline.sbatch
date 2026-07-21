#!/bin/bash
#SBATCH --job-name=caiman_master
# Resources come from the registry (miniscope/resources.yaml) when submitted via `run`.
#SBATCH --partition=illorent
#SBATCH --nodes=1
#SBATCH --time=7-00:00:00
# No --output/--error here: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh,
# sourced automatically via ~/.bashrc) point these at an organized, global
# location under $SCRATCH/logs/caiman_master/ regardless of where this gets
# submitted from. Falls back to Slurm's default (slurm-%j.out in the
# submission directory) if those env vars aren't set for some reason.
#
# Full pipeline, full sweep only (no per-mouse/per-session mode here -- use
# motion_correction.sbatch / cnmfe.sbatch directly for that). Enforces the
# hard gate: every session motion correction can find gets processed and
# verified BEFORE any CNMF-E starts. If verification finds leftover MC work
# after the sweep (a failure, or something new that appeared mid-run), the
# job aborts rather than silently starting CNMF-E on an incomplete state.

# NOTE: sbatch runs this script from a copied/spooled path, not its real
# location, so BASH_SOURCE-derived paths don't work here. CAIMAN_ROOT points
# at the `current` symlink the deploy agent maintains (see
# deploy/poll_and_deploy.sh) instead.
CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/miniscope}"
source "$CAIMAN_ROOT/common/pipeline_common.sh"

echo "=========================================="
echo "caiman master pipeline starting: $(date)"
echo "=========================================="

# --- stage 1: motion correction, full sweep ---------------------------------

echo ""
echo "stage 1: motion correction"

MC_SESSIONS_FILE="$LOG_DIR/master_mc_sessions_${SLURM_JOB_ID}.txt"
mc_queue > "$MC_SESSIONS_FILE"
MC_COUNT=$(grep -c . "$MC_SESSIONS_FILE" || true)
echo "sessions needing MC: $MC_COUNT"
if [ "$MC_COUNT" -gt 0 ]; then
  cat "$MC_SESSIONS_FILE"
fi

MC_FAILURES=0
if [ "$MC_COUNT" -gt 0 ]; then
  SESSION_NUM=0
  while IFS='|' read -r S_MOUSE S_DATE S_TP; do
    [ -z "$S_MOUSE" ] && continue
    SESSION_NUM=$((SESSION_NUM + 1))
    echo ""
    echo "[MC $SESSION_NUM/$MC_COUNT] $S_MOUSE/$S_DATE/$S_TP"
    if ! run_motion_correction "$S_MOUSE" "$S_DATE" "$S_TP"; then
      MC_FAILURES=$((MC_FAILURES + 1))
    fi
  done < "$MC_SESSIONS_FILE"
fi
rm -f "$MC_SESSIONS_FILE"

echo ""
echo "stage 1 complete, failures: $MC_FAILURES"

# --- gate: verify nothing is left needing MC before proceeding --------------

echo ""
echo "gate: re-checking for outstanding MC work"

GATE_CHECK_FILE="$LOG_DIR/master_gate_check_${SLURM_JOB_ID}.txt"
mc_queue > "$GATE_CHECK_FILE"
GATE_COUNT=$(grep -c . "$GATE_CHECK_FILE" || true)

if [ "$GATE_COUNT" -gt 0 ]; then
  echo "GATE FAILED: $GATE_COUNT session(s) still need motion correction, refusing to start CNMF-E"
  cat "$GATE_CHECK_FILE"
  rm -f "$GATE_CHECK_FILE"
  echo ""
  echo "master pipeline aborted: $(date)"
  exit 1
fi
rm -f "$GATE_CHECK_FILE"

echo "gate passed: no outstanding MC work"

# --- stage 2: CNMF-E, full sweep --------------------------------------------

echo ""
echo "stage 2: CNMF-E"

CNMFE_SESSIONS_FILE="$LOG_DIR/master_cnmfe_sessions_${SLURM_JOB_ID}.txt"
cnmfe_queue > "$CNMFE_SESSIONS_FILE"
CNMFE_COUNT=$(grep -c . "$CNMFE_SESSIONS_FILE" || true)
echo "sessions ready for CNMF-E: $CNMFE_COUNT"
if [ "$CNMFE_COUNT" -gt 0 ]; then
  cat "$CNMFE_SESSIONS_FILE"
fi

CNMFE_FAILURES=0
if [ "$CNMFE_COUNT" -gt 0 ]; then
  SESSION_NUM=0
  while IFS='|' read -r S_MOUSE S_DATE S_TP; do
    [ -z "$S_MOUSE" ] && continue
    SESSION_NUM=$((SESSION_NUM + 1))
    echo ""
    echo "[CNMFE $SESSION_NUM/$CNMFE_COUNT] $S_MOUSE/$S_DATE/$S_TP"
    if ! run_cnmfe "$S_MOUSE" "$S_DATE" "$S_TP"; then
      CNMFE_FAILURES=$((CNMFE_FAILURES + 1))
    fi
  done < "$CNMFE_SESSIONS_FILE"
fi
rm -f "$CNMFE_SESSIONS_FILE"

echo ""
echo "=========================================="
echo "master pipeline complete: $(date)"
echo "MC failures: $MC_FAILURES, CNMF-E failures: $CNMFE_FAILURES"
echo "NOTE: .mmap/.avi were excluded from CNMF-E sync, run a manual sync if needed"
echo "=========================================="

if [ "$MC_FAILURES" -gt 0 ] || [ "$CNMFE_FAILURES" -gt 0 ]; then
  exit 1
fi
