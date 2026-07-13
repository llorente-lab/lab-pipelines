#!/bin/bash
#SBATCH --job-name=caiman_pipeline_test
#SBATCH --partition=illorent
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:20:00
# No --output/--error here: SBATCH_OUTPUT/SBATCH_ERROR (set in env_setup.sh,
# sourced automatically via ~/.bashrc) point these at an organized, global
# location under $SCRATCH/logs/caiman_pipeline_test/ regardless of where
# this gets submitted from.
#
# End-to-end smoke test: generates a tiny synthetic session, runs the real
# motion_correct.py on it, then the real sync.sh, and checks the expected
# outputs landed in the right places -- local scratch AND Drive. Takes a
# couple minutes, not hours, since the sample video is 90 frames at 100x100.
#
# Uses a dedicated test identity (pipeline_test_mouse, doesn't start with
# "VK_") and a dedicated scratch subfolder, so this never touches real
# session data or shows up in real reconciliation output. Run
# cleanup_test_data.sh afterward to remove what this leaves behind.
#
#   sbatch run_mc_sync_test.sbatch

CAIMAN_ROOT="${CAIMAN_ROOT:-${GROUP_HOME:-$HOME}/pipelines/current/miniscope}"
source "$CAIMAN_ROOT/common/env_setup.sh"
set -euo pipefail

TESTS_DIR="$CAIMAN_ROOT_DIR/tests"

MOUSE="pipeline_test_mouse"
DATE="2020-01-01"
TP="test-session"

TEST_RAW_BASE="$SCRATCH/Miniscope/_pipeline_test/RawData"
TEST_ANALYZED_BASE="$SCRATCH/Miniscope/_pipeline_test/AnalyzedData"

echo "pipeline smoke test starting: $(date)"
echo "session: $MOUSE/$DATE/$TP"
echo "raw base:      $TEST_RAW_BASE"
echo "analyzed base: $TEST_ANALYZED_BASE"

# --- step 1: generate sample data --------------------------------------------

echo ""
echo "step 1: generating sample data"
apptainer_python "$TESTS_DIR/generate_sample_data.py" --raw-base "$TEST_RAW_BASE"

# --- step 2: run the real motion correction script ---------------------------

echo ""
echo "step 2: running motion_correct.py"
apptainer_python "$CAIMAN_MC_DIR/motion_correct.py" "$MOUSE" "$DATE" "$TP" \
  --raw-base "$TEST_RAW_BASE" --analyzed-base "$TEST_ANALYZED_BASE"

OUT_DIR="$TEST_ANALYZED_BASE/$MOUSE/$DATE/$TP"
FAILURES=0

check_file() {
  if [ -f "$1" ]; then
    echo "PASS - found $1"
  else
    echo "FAIL - missing $1"
    FAILURES=$((FAILURES + 1))
  fi
}

echo ""
echo "step 2 checks:"
check_file "$OUT_DIR/correlation_image.npy"
MMAP_COUNT=$(find "$OUT_DIR" -name "*order_c*.mmap" 2>/dev/null | wc -l)
if [ "$MMAP_COUNT" -gt 0 ]; then
  echo "PASS - found $MMAP_COUNT order_c mmap file(s)"
else
  echo "FAIL - no order_c mmap file found under $OUT_DIR"
  FAILURES=$((FAILURES + 1))
fi

# --- step 3: sync it back with the real sync.sh -------------------------------

echo ""
echo "step 3: running sync.sh"
MINISCOPE_ANALYZED_BASE="$TEST_ANALYZED_BASE" MINISCOPE_DRIVE_PREFIX="Miniscope/_pipeline_test" \
  bash "$CAIMAN_COMMON_DIR/sync.sh" "$MOUSE" "$DATE" "$TP"

echo ""
echo "step 3 check: confirming correlation_image.npy landed on Drive"
DEST="gdrive:Miniscope/_pipeline_test/AnalyzedData/$MOUSE/$DATE/$TP"
if apptainer_rclone lsf "$DEST" 2>/dev/null | grep -q correlation_image; then
  echo "PASS - correlation_image.npy present at $DEST"
else
  echo "FAIL - correlation_image.npy not found at $DEST"
  FAILURES=$((FAILURES + 1))
fi

echo ""
echo "pipeline smoke test complete: $(date)"
echo "failures: $FAILURES"
echo "run tests/cleanup_test_data.sh to remove everything this left behind"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
