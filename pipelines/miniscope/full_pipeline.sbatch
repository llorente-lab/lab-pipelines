#!/bin/bash
#SBATCH --job-name=caiman_full_pipeline
#SBATCH --partition=illorent
#SBATCH --nodes=1
#SBATCH --time=7-00:00:00
# No --output/--error: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh) route logs to
# $SCRATCH/logs/caiman_full_pipeline/. Falls back to slurm-%j.out if those vars aren't set.
#
# Full sweep only. Enforces a hard gate: if any MC work remains after the sweep, the
# job aborts rather than silently starting CNMF-E on an incomplete state.

# sbatch spools scripts to a temp path, so BASH_SOURCE-derived paths don't work here.
CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/pipelines/miniscope}"
source "$CAIMAN_ROOT/common/pipeline_common.sh"

mkdir -p "$SCRATCH/logs/resource_monitor"
start_resource_monitor "$SCRATCH/logs/resource_monitor/full_pipeline_${SLURM_JOB_ID}.tsv"

echo "=========================================="
echo "caiman full pipeline starting: $(date)"
echo "=========================================="

echo ""
echo "stage 1: motion correction"

MC_SESSIONS_FILE="$LOG_DIR/full_pipeline_mc_sessions_${SLURM_JOB_ID}.txt"
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

echo ""
echo "gate: re-checking for outstanding MC work"

GATE_CHECK_FILE="$LOG_DIR/full_pipeline_gate_check_${SLURM_JOB_ID}.txt"
mc_queue > "$GATE_CHECK_FILE"
GATE_COUNT=$(grep -c . "$GATE_CHECK_FILE" || true)

if [ "$GATE_COUNT" -gt 0 ]; then
  echo "GATE FAILED: $GATE_COUNT session(s) still need motion correction, refusing to start CNMF-E"
  cat "$GATE_CHECK_FILE"
  rm -f "$GATE_CHECK_FILE"
  echo ""
  echo "full pipeline aborted: $(date)"
  exit 1
fi
rm -f "$GATE_CHECK_FILE"

echo "gate passed: no outstanding MC work"

echo ""
echo "stage 2: CNMF-E"

CNMFE_SESSIONS_FILE="$LOG_DIR/full_pipeline_cnmfe_sessions_${SLURM_JOB_ID}.txt"
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
echo "full pipeline complete: $(date)"
echo "MC failures: $MC_FAILURES, CNMF-E failures: $CNMFE_FAILURES"
echo "NOTE: .mmap/.avi were excluded from CNMF-E sync, run a manual sync if needed"
echo "=========================================="

if [ "$MC_FAILURES" -gt 0 ] || [ "$CNMFE_FAILURES" -gt 0 ]; then
  exit 1
fi
