#!/bin/bash
# Full smoke test for the Moseq pipeline: synthetic session -> extraction ->
# aggregate -> PCA fit -> PCA apply -> changepoints -> kappa-scan, submitted
# and polled for real via Slurm, on Sherlock. Same spirit as
# miniscope/tests/run_mc_sync_test.sbatch, adapted to Moseq's chained,
# multi-stage, single-exclusive-node submission model (submit_master() plus
# one extra kappa-scan call, since submit_master() deliberately doesn't
# include modeling).
#
# Run this directly (not via sbatch) from a login node or an interactive
# allocation -- it only submits jobs and polls sacct, it doesn't need
# compute resources itself. Expect this to take a while: everything runs
# strictly sequentially on the lab's one --exclusive illorent node.
#
# Usage:
#   bash tests/test_full_pipeline.sh [n_frames] [size]
#
# Everything lives in a dedicated sandbox project, never a real one:
#   $MOSEQ_PROJECTS_BASE/_pipeline_test/
#
# Run tests/cleanup_pipeline_test.sh afterward to remove it.

set -uo pipefail  # NOT -e: we want to keep going through checks and report
                   # a full summary at the end, not bail on the first failed
                   # assertion.

MOSEQ_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source directly, rather than relying on the caller having already sourced
# it interactively: apptainer_python/apptainer_exec are shell functions, and
# functions (unlike exported env vars) are NOT inherited by a `bash
# script.sh` child process unless the parent explicitly ran `export -f` on
# them -- env_setup.sh doesn't do that. So even if you already sourced
# env_setup.sh in your interactive shell, this script's own `bash` process
# starts with no knowledge of those functions unless it sources the file
# itself too. Safe to source twice (idempotent PATH/JUPYTER_PATH checks).
source "$MOSEQ_COMMON_DIR/env_setup.sh"

# submit_moseq.py runs on the HOST, not inside the container, and uses
# `from __future__ import annotations` (needs Python 3.7+). Sherlock login
# nodes default `python3` to the ancient system Python 3.6.8, which doesn't
# support that syntax at all -- same root cause as poll_and_deploy.sh's git
# version workaround. Prepend a modern Python onto PATH unconditionally,
# the same way, rather than assuming the caller's shell already has one.
PYTHON_MODULE_BIN="/share/software/user/open/python/3.9.0/bin"
[ -d "$PYTHON_MODULE_BIN" ] && PATH="$PYTHON_MODULE_BIN:$PATH"
PY_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "0.0")"
if [ "$(printf '%s\n%s\n' "3.7" "$PY_VERSION" | sort -V | head -n1)" != "3.7" ]; then
  echo "fatal: python3 on PATH ($(command -v python3), version $PY_VERSION) is older than 3.7, submit_moseq.py needs 'from __future__ import annotations'." >&2
  echo "fatal: expected a modern python3 at $PYTHON_MODULE_BIN -- check it still exists and update PYTHON_MODULE_BIN above if the version changed." >&2
  exit 1
fi

if [ -z "${MOSEQ_SIF-}" ]; then
  echo "MOSEQ_SIF is still not set after sourcing env_setup.sh -- something's wrong with the environment." >&2
  exit 1
fi

N_FRAMES="${1:-300}"
SIZE="${2:-80}"

PROJECT_ROOT="$MOSEQ_PROJECTS_BASE/_pipeline_test"
mkdir -p "$PROJECT_ROOT"

PASS=0
FAIL=0
check() {
  # check <description> <path that must exist>
  if [ -e "$2" ]; then
    echo "  [PASS] $1"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $1 (missing: $2)"
    FAIL=$((FAIL + 1))
  fi
}

wait_for_job() {
  # Polls sacct until job $1 leaves the queue (COMPLETED, FAILED, CANCELLED,
  # TIMEOUT, ...). Prints the final state. sacct, not squeue, since squeue
  # stops showing a job the instant it finishes -- sacct keeps history.
  local jobid="$1"
  local state
  while true; do
    state="$(sacct -j "$jobid" --format=State --noheader --parsable2 2>/dev/null | head -1 | tr -d ' ')"
    case "$state" in
      COMPLETED) echo "COMPLETED"; return 0 ;;
      FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY) echo "$state"; return 1 ;;
      "") sleep 10 ;;   # sacct hasn't indexed it yet
      *) sleep 10 ;;    # PENDING / RUNNING / etc, keep waiting
    esac
  done
}

echo "==================================================================="
echo "Moseq full pipeline smoke test"
echo "project: $PROJECT_ROOT"
echo "frames: $N_FRAMES | size: ${SIZE}x${SIZE}"
echo "==================================================================="

# --- 0. synthetic session --------------------------------------------------
echo
echo ">>> generating synthetic session"
apptainer_python "$TESTS_DIR/generate_sample_data.py" "$PROJECT_ROOT" --frames "$N_FRAMES" --size "$SIZE"
check "depth.dat written" "$PROJECT_ROOT/session_a/depth.dat"
check "depth_ts.txt written" "$PROJECT_ROOT/session_a/depth_ts.txt"
check "metadata.json written" "$PROJECT_ROOT/session_a/metadata.json"

# --- 1. config -------------------------------------------------------------
echo
echo ">>> generating config.yaml"
apptainer_exec moseq2-extract generate-config -o "$PROJECT_ROOT/config.yaml"
check "config.yaml written" "$PROJECT_ROOT/config.yaml"

# --- 2. submit the chained extract -> aggregate -> pca_fit -> pca_apply ->
#        changepoints pipeline via submit_master() ------------------------
echo
echo ">>> submitting master chain (extract -> aggregate -> pca_fit -> pca_apply -> changepoints)"
cd "$MOSEQ_COMMON_DIR"
JOB_JSON="$(python3 -c "
import json, submit_moseq
jobs = submit_moseq.submit_master('$PROJECT_ROOT')
print(json.dumps(jobs))
")"
echo "submitted: $JOB_JSON"

CHANGEPOINTS_JOB="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['compute_changepoints'])" "$JOB_JSON")"
echo "waiting on final stage (changepoints), job $CHANGEPOINTS_JOB ..."
FINAL_STATE="$(wait_for_job "$CHANGEPOINTS_JOB")"
echo "changepoints job finished: $FINAL_STATE"

echo
echo ">>> checking outputs"
check "extraction proc/ dir"        "$PROJECT_ROOT/session_a/proc"
check "extraction results h5"       "$PROJECT_ROOT/session_a/proc/results_00.h5"
check "aggregate_results/"          "$PROJECT_ROOT/aggregate_results"
check "moseq2-index.yaml"           "$PROJECT_ROOT/moseq2-index.yaml"
check "pca.h5"                      "$PROJECT_ROOT/_pca/pca.h5"
check "pca_scree.png"               "$PROJECT_ROOT/_pca/pca_scree.png"
check "pca_scores.h5 (pca_apply)"   "$PROJECT_ROOT/_pca/pca_scores.h5"
check "changepoints.h5"             "$PROJECT_ROOT/_pca/changepoints.h5"

echo "npcs selected (from compute_npcs.py, should be in config.yaml):"
grep npcs "$PROJECT_ROOT/config.yaml" || echo "  (not found)"

# --- 3. kappa-scan (not part of submit_master() on purpose -- separate,
#        explicit step, see submit_moseq.py's docstring) -------------------
if [ "$FINAL_STATE" = "COMPLETED" ]; then
  echo
  echo ">>> submitting kappa-scan (small: 3 models, 20 iters -- smoke test only)"
  KAPPA_JOB="$(python3 -c "
import submit_moseq
print(submit_moseq.submit_kappa_scan('$PROJECT_ROOT', n_models=3, num_iter=20))
")"
  echo "waiting on kappa-scan, job $KAPPA_JOB ..."
  KAPPA_STATE="$(wait_for_job "$KAPPA_JOB")"
  echo "kappa-scan job finished: $KAPPA_STATE"

  check "models dir"              "$PROJECT_ROOT/models"
  check "best_kappa_selection.json (select_best_kappa.py)" "$PROJECT_ROOT/models/best_kappa_selection.json"

  if [ -f "$PROJECT_ROOT/models/best_kappa_selection.json" ]; then
    echo "best_kappa_selection.json contents:"
    cat "$PROJECT_ROOT/models/best_kappa_selection.json"
  fi
else
  echo
  echo ">>> skipping kappa-scan: upstream chain did not COMPLETE ($FINAL_STATE)"
fi

# --- summary ----------------------------------------------------------------
echo
echo "==================================================================="
echo "logs: $PROJECT_ROOT/slurm_logs/"
echo "PASS: $PASS  FAIL: $FAIL"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
