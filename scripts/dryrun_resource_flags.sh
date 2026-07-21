#!/bin/bash
# Dry-run validator for the --exclusive/--cores/--mem/--time overrides on
# real Sherlock, without submitting or running anything. Prepends a fake
# `sbatch` (a real wrapper executable on $PATH, not a bash function -- a
# function shadow wouldn't catch moseq's Python subprocess.run(["sbatch",
# ...]) calls, which bypass the shell entirely) that adds --test-only and
# execs the real sbatch. --test-only fully validates the job (partition,
# walltime, resource fit) and reports a start estimate or rejection reason,
# without queuing anything -- zero compute cost, safe to rerun.
#
# Usage (after sourcing both pipelines' env_setup.sh):
#   bash scripts/dryrun_resource_flags.sh
#
# "sbatch: Job <id> to start at ..." = accepted. "sbatch: error: ..." =
# rejected, message says why (e.g. a walltime over the account's MaxWall).
#
# Creates one scratch project ($MOSEQ_PROJECTS_BASE/_flag_dryrun_test) to
# point moseq stages at, removed via the trap below even on Ctrl-C.

set -uo pipefail  # deliberately not -e: one rejected combination shouldn't stop the rest

TEST_PROJECT="_flag_dryrun_test"
PASS=0
FAIL=0

_header() {
  echo ""
  echo "=================================================================="
  echo "$1"
  echo "=================================================================="
}

_run() {
  echo "--- $* ---"
  if "$@" 2>&1 | tee /tmp/_dryrun_out.$$; then :; fi
  if grep -q "to start at\|will be scheduled" /tmp/_dryrun_out.$$ 2>/dev/null; then
    echo "  => ACCEPTED"
    PASS=$((PASS + 1))
  elif grep -qi "error" /tmp/_dryrun_out.$$ 2>/dev/null; then
    echo "  => REJECTED (see message above)"
    FAIL=$((FAIL + 1))
  else
    echo "  => no sbatch call happened (e.g. 'nothing to do') -- not counted either way"
  fi
  rm -f /tmp/_dryrun_out.$$
  echo ""
}

REAL_SBATCH="$(command -v sbatch)"
if [ -z "$REAL_SBATCH" ]; then
  echo "fatal: sbatch not found on PATH -- are you on a Sherlock login/compute node with Slurm loaded?" >&2
  exit 1
fi

DRYRUN_BIN_DIR="$(mktemp -d)"
cat > "$DRYRUN_BIN_DIR/sbatch" <<WRAPPER
#!/bin/bash
exec "$REAL_SBATCH" --test-only "\$@"
WRAPPER
chmod +x "$DRYRUN_BIN_DIR/sbatch"
export PATH="$DRYRUN_BIN_DIR:$PATH"
echo "sbatch intercepted: $(command -v sbatch) -> wraps $REAL_SBATCH --test-only"
echo ""

_cleanup() {
  rm -rf "$DRYRUN_BIN_DIR"
  if [ -n "${MOSEQ_PROJECTS_BASE:-}" ] && [ -d "$MOSEQ_PROJECTS_BASE/$TEST_PROJECT" ]; then
    rm -rf "${MOSEQ_PROJECTS_BASE:?}/$TEST_PROJECT"
    echo "cleaned up $MOSEQ_PROJECTS_BASE/$TEST_PROJECT"
  fi
}
trap _cleanup EXIT

# --- miniscope ---------------------------------------------------------
_header "MINISCOPE: motion-correction"
_run run miniscope motion-correction --mouse dryrun_mouse --date 2025-01-01 --tp tp1
_run run miniscope motion-correction --mouse dryrun_mouse --date 2025-01-01 --tp tp1 --exclusive
_run run miniscope motion-correction --mouse dryrun_mouse --date 2025-01-01 --tp tp1 --cores 64 --mem 200 --time 1-00:00:00
_run run miniscope motion-correction --mouse dryrun_mouse --date 2025-01-01 --tp tp1 --exclusive --cores 32

_header "MINISCOPE: cnmfe"
_run run miniscope cnmfe --mouse dryrun_mouse --date 2025-01-01 --tp tp1
_run run miniscope cnmfe --mouse dryrun_mouse --date 2025-01-01 --tp tp1 --exclusive
_run run miniscope cnmfe --mouse dryrun_mouse --date 2025-01-01 --tp tp1 --cores 64 --mem 200 --time 1-00:00:00

_header "MINISCOPE: master"
_run run miniscope master
_run run miniscope master --exclusive
_run run miniscope master --cores 128 --mem 800 --time 1-00:00:00

_header "MINISCOPE: multisession"
_run run miniscope multisession --mouse dryrun_mouse
_run run miniscope multisession --mouse dryrun_mouse --exclusive

# --- moseq --------------------------------------------------------------
_header "MOSEQ: setting up scratch test project"
run moseq init "$TEST_PROJECT" >/dev/null 2>&1
echo "created $MOSEQ_PROJECTS_BASE/$TEST_PROJECT"

_header "MOSEQ: extract (expect --exclusive to warn+no-op; likely 'nothing to extract' since no real session data exists here)"
_run run moseq extract "$TEST_PROJECT"
_run run moseq extract "$TEST_PROJECT" --exclusive
_run run moseq extract "$TEST_PROJECT" --cores 16 --mem 64 --time 1-00:00:00

_header "MOSEQ: aggregate"
_run run moseq aggregate "$TEST_PROJECT"
_run run moseq aggregate "$TEST_PROJECT" --exclusive
_run run moseq aggregate "$TEST_PROJECT" --cores 16 --mem 64 --time 1-00:00:00
_run run moseq aggregate "$TEST_PROJECT" --exclusive --cores 8

_header "MOSEQ: pca-fit"
_run run moseq pca-fit "$TEST_PROJECT"
_run run moseq pca-fit "$TEST_PROJECT" --exclusive
_run run moseq pca-fit "$TEST_PROJECT" --cores 64 --mem 500 --time 1-12:00:00

_header "MOSEQ: pca-apply"
_run run moseq pca-apply "$TEST_PROJECT"
_run run moseq pca-apply "$TEST_PROJECT" --exclusive

_header "MOSEQ: changepoints"
_run run moseq changepoints "$TEST_PROJECT"
_run run moseq changepoints "$TEST_PROJECT" --exclusive

_header "MOSEQ: kappa-scan (default --time is now 2-00:00:00, the account's max, so this should be ACCEPTED)"
_run run moseq kappa-scan "$TEST_PROJECT" --n-models 5
_run run moseq kappa-scan "$TEST_PROJECT" --n-models 5 --exclusive
_run run moseq kappa-scan "$TEST_PROJECT" --n-models 5 --cores 64 --mem 400 --time 2-00:00:00
_run run moseq kappa-scan "$TEST_PROJECT" --n-models 5 --time 10-00:00:00   # deliberately way over the 2-day cap -- SHOULD be rejected

_header "MOSEQ: learn-model (default --time is now 2-00:00:00, the account's max, so this should be ACCEPTED)"
_run run moseq learn-model "$TEST_PROJECT" --kappa 500
_run run moseq learn-model "$TEST_PROJECT" --kappa 500 --exclusive
_run run moseq learn-model "$TEST_PROJECT" --kappa 500 --cores 32 --mem 200 --time 1-00:00:00

_header "MOSEQ: master (only --exclusive should be accepted; --cores/--mem/--time should be REJECTED by the CLI itself, not by Slurm)"
_run run moseq master "$TEST_PROJECT"
_run run moseq master "$TEST_PROJECT" --exclusive
echo "--- run moseq master $TEST_PROJECT --cores 64  (expect a CLI-level error, not an sbatch call) ---"
run moseq master "$TEST_PROJECT" --cores 64
echo ""

_header "SUMMARY"
echo "accepted: $PASS   rejected: $FAIL"
echo "(rejections above are the interesting ones to actually read -- check whether they're"
echo " expected, like the deliberate 10-day kappa-scan overflow test, or a real problem)"
