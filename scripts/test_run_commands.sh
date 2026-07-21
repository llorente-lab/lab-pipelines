#!/bin/bash
# Assertion-based tests for `run`'s CLI dispatch/argument-validation logic:
# unknown pipelines/stages, required-argument checks, master's stricter
# flag rejection, help output, and (with sbatch stubbed) that a valid
# invocation actually reaches sbatch with the right script/args. Runs
# anywhere -- no Slurm, no container, no Sherlock needed -- since `run`
# itself only needs its pipelines' env_setup.sh sourced (which just sets
# env vars/paths) and a stubbed `sbatch` on PATH.
#
# Complements scripts/test_resource_params.sh (which focuses on the
# resource flags specifically) -- this one is about command dispatch and
# argument handling, independent of resources.
#
# Usage: bash scripts/test_run_commands.sh
# Exit code: 0 if every assertion passed, 1 if any failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/cli/run"
PASS=0
FAIL=0

_ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

_assert_contains() {
  if [[ "$1" == *"$2"* ]]; then _ok "$3"; else _fail "$3 (expected to find '$2' in: $1)"; fi
}

_assert_exit_code() {
  # _assert_exit_code <actual> <expected> <description>
  if [ "$1" -eq "$2" ]; then _ok "$3"; else _fail "$3 (exit $1, expected $2)"; fi
}

# --- sandbox: fake GROUP_SCRATCH/GROUP_HOME/SCRATCH + fake sbatch on PATH ---
SANDBOX="$(mktemp -d)"
export GROUP_SCRATCH="$SANDBOX/group_scratch"
export GROUP_HOME="$SANDBOX/group_home"
export SCRATCH="$SANDBOX/scratch"
mkdir -p "$GROUP_SCRATCH" "$GROUP_HOME" "$SCRATCH"

CAPTURE_FILE="$SANDBOX/sbatch_calls.log"
: > "$CAPTURE_FILE"
FAKE_BIN="$SANDBOX/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/sbatch" <<'WRAPPER'
#!/bin/bash
echo "$*" >> "$SBATCH_CAPTURE_FILE"
echo "Submitted batch job 999999"
WRAPPER
chmod +x "$FAKE_BIN/sbatch"
export SBATCH_CAPTURE_FILE="$CAPTURE_FILE"
export PATH="$FAKE_BIN:$PATH"

_cleanup() { rm -rf "$SANDBOX"; }
trap _cleanup EXIT

echo "=================================================================="
echo "Generic dispatch"
echo "=================================================================="

out="$("$CLI" 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run (no args) exits 0"
_assert_contains "$out" "run --" "run (no args) prints usage"

out="$("$CLI" --help 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run --help exits 0"
_assert_contains "$out" "moseq" "run --help mentions moseq"
_assert_contains "$out" "miniscope" "run --help mentions miniscope"

out="$("$CLI" bogus_pipeline foo 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run <unknown pipeline> exits 1"
_assert_contains "$out" "unknown command" "run <unknown pipeline> reports unknown command"

out="$("$CLI" list 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run list exits 0"
_assert_contains "$out" "moseq" "run list mentions moseq"
_assert_contains "$out" "miniscope" "run list mentions miniscope"

out="$("$CLI" logs bogus_pipeline 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run logs <unknown pipeline> exits 1"
_assert_contains "$out" "must be one of" "run logs <unknown pipeline> reports valid options"

echo ""
echo "=================================================================="
echo "moseq dispatch"
echo "=================================================================="

out="$("$CLI" moseq 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run moseq (no stage) exits 1"
_assert_contains "$out" "missing moseq stage" "run moseq (no stage) reports missing stage"

out="$("$CLI" moseq bogus-stage some_project 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run moseq <unknown stage> exits 1"
_assert_contains "$out" "unknown moseq stage" "run moseq <unknown stage> reports unknown stage"

out="$("$CLI" moseq help 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run moseq help exits 0"
_assert_contains "$out" "extract" "run moseq help lists extract"
_assert_contains "$out" "--exclusive" "run moseq help documents --exclusive"

out="$("$CLI" moseq extract --help 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run moseq extract --help exits 0"
_assert_contains "$out" "usage: run moseq extract" "run moseq extract --help shows stage usage"

out="$("$CLI" moseq extract nonexistent_project 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run moseq extract <missing project> exits 1"
_assert_contains "$out" "doesn't exist" "run moseq extract <missing project> reports missing project"

out="$("$CLI" moseq init _cli_test_project 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run moseq init creates a project"
_assert_contains "$out" "created" "run moseq init reports creation"

: > "$CAPTURE_FILE"
out="$("$CLI" moseq extract _cli_test_project 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run moseq extract on an empty project exits 0"
_assert_contains "$out" "nothing to extract" "run moseq extract on an empty project reports nothing to do"
calls="$(cat "$CAPTURE_FILE")"
if [ -z "$calls" ]; then _ok "no sbatch call made when nothing needs extraction"; else _fail "sbatch was called even though nothing needed extraction"; fi

out="$("$CLI" moseq master _cli_test_project --cores 8 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run moseq master --cores is rejected at the CLI level"
_assert_contains "$out" "only --exclusive is supported" "run moseq master --cores gives the right error"

out="$("$CLI" moseq learn-model _cli_test_project 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run moseq learn-model without --kappa exits 1"
_assert_contains "$out" "--kappa is required" "run moseq learn-model reports missing --kappa"

rm -rf "${GROUP_SCRATCH:?}/Moseq/_cli_test_project" 2>/dev/null

echo ""
echo "=================================================================="
echo "miniscope dispatch"
echo "=================================================================="

out="$("$CLI" miniscope help 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run miniscope help exits 0"
_assert_contains "$out" "motion-correction" "run miniscope help lists motion-correction"

out="$("$CLI" miniscope bogus-stage 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run miniscope <unknown stage> exits 1"

out="$("$CLI" miniscope master --mouse foo 2>&1)"; code=$?
_assert_exit_code "$code" 1 "run miniscope master --mouse (unsupported flag) is rejected"
_assert_contains "$out" "unrecognized argument" "run miniscope master reports unrecognized argument"

: > "$CAPTURE_FILE"
out="$("$CLI" miniscope motion-correction --mouse dryrun_mouse --date 2025-01-01 --tp tp1 2>&1)"; code=$?
_assert_exit_code "$code" 0 "run miniscope motion-correction with valid args exits 0"
call="$(cat "$CAPTURE_FILE")"
_assert_contains "$call" "motion_correction.sbatch" "the correct .sbatch script is invoked"
_assert_contains "$call" "dryrun_mouse" "the mouse argument reaches sbatch"
_assert_contains "$call" "2025-01-01" "the date argument reaches sbatch"
_assert_contains "$call" "tp1" "the tp argument reaches sbatch"

echo ""
echo "=================================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
