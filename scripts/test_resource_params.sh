#!/bin/bash
# Assertion-based tests for the --exclusive/--cores/--mem/--time resource
# parameters -- both the shared bash helpers (cli/resources.sh, used by
# miniscope) and the Python equivalent (submit_moseq.py's _resource_flags,
# used by moseq). Unlike scripts/dryrun_resource_flags.sh (which needs a
# real Sherlock login node with Slurm installed, and only eyeballs
# ACCEPTED/REJECTED), this script runs anywhere -- no Slurm required -- by
# stubbing `sbatch` with a fake executable that just records its argv, and
# asserts on the EXACT flags produced for each case instead of just
# checking a submission was accepted.
#
# Usage: bash scripts/test_resource_params.sh
# Exit code: 0 if every assertion passed, 1 if any failed.

set -uo pipefail  # not -e: one failed assertion shouldn't stop the rest

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

_ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

_assert_contains() {
  # _assert_contains "<haystack>" "<needle>" "<description>"
  if [[ "$1" == *"$2"* ]]; then _ok "$3"; else _fail "$3 (expected to find '$2' in: $1)"; fi
}

_assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then _ok "$3"; else _fail "$3 (did not expect to find '$2' in: $1)"; fi
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
# Records the full argv (one call per line, flags space-joined) and
# returns a fake job ID -- no real Slurm involved.
echo "$*" >> "$SBATCH_CAPTURE_FILE"
echo "Submitted batch job 999999"
WRAPPER
chmod +x "$FAKE_BIN/sbatch"
export SBATCH_CAPTURE_FILE="$CAPTURE_FILE"
export PATH="$FAKE_BIN:$PATH"

_cleanup() { rm -rf "$SANDBOX"; }
trap _cleanup EXIT

echo "=================================================================="
echo "PART 1: cli/resources.sh (miniscope's bash helpers)"
echo "=================================================================="

# shellcheck disable=SC1091
source "$REPO_ROOT/pipelines/miniscope/common/env_setup.sh" >/dev/null 2>&1
CLI_DIR="$REPO_ROOT/cli"
# shellcheck disable=SC1091
source "$CLI_DIR/resources.sh"

# _set_resource_flags/_force_exclusive just record state now -- the actual
# registry lookup + flag computation happens once, in _apply_resource_overrides
# (a single call into estimate_resources.py's resource_flags()), same contract
# miniscope.sh already relies on (it always calls _apply_resource_overrides
# last, even with empty overrides).
echo "-- _set_resource_flags + _apply_resource_overrides (no overrides): registry defaults --"
_set_resource_flags miniscope motion-correction "n_sessions=1"
_apply_resource_overrides "" "" ""
flags="${RESOURCE_FLAGS[*]}"
_assert_contains "$flags" "--partition=" "sets a --partition"
_assert_contains "$flags" "--cpus-per-task=" "sets --cpus-per-task from the registry"
_assert_contains "$flags" "--mem=" "sets --mem from the registry"

echo "-- _force_exclusive strips cores/mem, adds --exclusive once --"
_force_exclusive
_apply_resource_overrides "" "" ""
flags="${RESOURCE_FLAGS[*]}"
_assert_not_contains "$flags" "--cpus-per-task=" "--force_exclusive strips --cpus-per-task"
_assert_not_contains "$flags" "--mem=" "--force_exclusive strips --mem"
_assert_contains "$flags" "--exclusive" "--force_exclusive adds --exclusive"
exclusive_count=$(grep -o -- "--exclusive" <<<"$flags" | wc -l)
if [ "$exclusive_count" -eq 1 ]; then _ok "--exclusive appears exactly once"; else _fail "--exclusive appears $exclusive_count times (expected 1)"; fi

echo "-- _apply_resource_overrides wins over --exclusive's stripped cores/mem --"
_apply_resource_overrides "32" "128" "1-00:00:00"
flags="${RESOURCE_FLAGS[*]}"
_assert_contains "$flags" "--cpus-per-task=32" "explicit --cores override applied on top of --exclusive"
_assert_contains "$flags" "--mem=128G" "explicit --mem override applied on top of --exclusive"
_assert_contains "$flags" "--time=1-00:00:00" "explicit --time override applied"
_assert_contains "$flags" "--exclusive" "--exclusive still present alongside explicit cores/mem"

echo "-- fresh call: overrides alone (no --exclusive) --"
_set_resource_flags miniscope cnmfe
_apply_resource_overrides "" "64" ""
flags="${RESOURCE_FLAGS[*]}"
_assert_contains "$flags" "--mem=64G" "--mem override applied without --exclusive"
_assert_not_contains "$flags" "--exclusive" "no --exclusive when not requested"

echo ""
echo "=================================================================="
echo "PART 2: submit_moseq.py's _resource_flags (moseq's Python helper)"
echo "=================================================================="

# shellcheck disable=SC1091
source "$REPO_ROOT/pipelines/moseq/common/env_setup.sh" >/dev/null 2>&1

PY_RESULT="$(PYTHONPATH="$MOSEQ_COMMON_DIR" python3 - <<'PYEOF'
import json
import submit_moseq as sm

out = {}
out["defaults"] = sm._resource_flags("aggregate", {})
out["exclusive"] = sm._resource_flags("aggregate", {}, exclusive=True)
out["exclusive_with_cores"] = sm._resource_flags("aggregate", {}, exclusive=True, cores=8)
out["cores_mem_time_override"] = sm._resource_flags("aggregate", {}, cores=16, mem_gb=200, time="1-00:00:00")
out["pca_fit_formula"] = sm._resource_flags("pca-fit", {"n_sessions": 4})
print(json.dumps(out))
PYEOF
)"

defaults="$(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])['defaults']))" "$PY_RESULT")"
_assert_contains "$defaults" "--partition=" "aggregate defaults set --partition"
_assert_contains "$defaults" "--cpus-per-task=" "aggregate defaults set --cpus-per-task (fallback)"
_assert_contains "$defaults" "--mem=" "aggregate defaults set --mem (fallback)"

excl="$(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])['exclusive']))" "$PY_RESULT")"
_assert_contains "$excl" "--exclusive" "exclusive=True adds --exclusive"
_assert_not_contains "$excl" "--cpus-per-task=" "exclusive=True drops formula-derived --cpus-per-task"
_assert_not_contains "$excl" "--mem=" "exclusive=True drops formula-derived --mem"

excl_cores="$(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])['exclusive_with_cores']))" "$PY_RESULT")"
_assert_contains "$excl_cores" "--exclusive" "exclusive=True + explicit cores keeps --exclusive"
_assert_contains "$excl_cores" "--cpus-per-task=8" "exclusive=True + explicit cores=8 still honors the explicit cores"

override="$(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])['cores_mem_time_override']))" "$PY_RESULT")"
_assert_contains "$override" "--cpus-per-task=16" "explicit cores=16 overrides the registry"
_assert_contains "$override" "--mem=200G" "explicit mem_gb=200 overrides the registry"
_assert_contains "$override" "--time=1-00:00:00" "explicit time is appended"

pca_fit="$(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])['pca_fit_formula']))" "$PY_RESULT")"
_assert_contains "$pca_fit" "--mem=" "pca-fit's n_sessions-based mem_gb formula produces a --mem value"
# pca-fit's formula is "n_sessions * 50" with a 100 floor -- 4 sessions -> 200GB, well above the floor.
_assert_contains "$pca_fit" "--mem=200G" "pca-fit mem_gb formula computes n_sessions*50 correctly (4*50=200)"

echo ""
echo "=================================================================="
echo "PART 2.5: estimate_resources.py -- list-valued partition (multi-partition eligibility)"
echo "=================================================================="

LIST_PARTITION_YAML="$SANDBOX/list_partition_resources.yaml"
cat > "$LIST_PARTITION_YAML" <<'YAML'
stages:
  test-stage:
    partition: [illorent, normal]
    exclusive: false
    cores:
      formula: null
      fallback: 16
    mem_gb:
      formula: null
      fallback: 50
YAML

list_partition_flags="$(python3 "$CLI_DIR/estimate_resources.py" "$LIST_PARTITION_YAML" test-stage | tr '\n' ' ')"
_assert_contains "$list_partition_flags" "--partition=illorent,normal" "a YAML list partition becomes a comma-joined --partition flag"
_assert_not_contains "$list_partition_flags" "--partition=['" "list partition is never emitted as a raw Python repr"

echo ""
echo "=================================================================="
echo "PART 3: end-to-end through the real \`run\` CLI (sbatch stubbed, no Slurm)"
echo "=================================================================="

: > "$CAPTURE_FILE"
CLI_DIR="$REPO_ROOT/cli"
"$CLI_DIR/run" miniscope motion-correction --mouse dryrun_mouse --date 2025-01-01 --tp tp1 \
  --exclusive --cores 40 --mem 300 --time 1-00:00:00 >/dev/null 2>&1
call="$(tail -n1 "$CAPTURE_FILE")"
_assert_contains "$call" "--exclusive" "run miniscope motion-correction --exclusive reaches sbatch"
_assert_contains "$call" "--cpus-per-task=40" "run miniscope motion-correction --cores 40 reaches sbatch"
_assert_contains "$call" "--mem=300G" "run miniscope motion-correction --mem 300 reaches sbatch"
_assert_contains "$call" "--time=1-00:00:00" "run miniscope motion-correction --time reaches sbatch"
_assert_contains "$call" "motion_correction.sbatch" "correct .sbatch script invoked"

: > "$CAPTURE_FILE"
"$CLI_DIR/run" moseq init _resource_param_test >/dev/null 2>&1
"$CLI_DIR/run" moseq aggregate _resource_param_test --exclusive --cores 12 >/dev/null 2>&1
call="$(tail -n1 "$CAPTURE_FILE")"
_assert_contains "$call" "--exclusive" "run moseq aggregate --exclusive reaches sbatch"
_assert_contains "$call" "--cpus-per-task=12" "run moseq aggregate --cores 12 reaches sbatch"
rm -rf "${MOSEQ_PROJECTS_BASE:?}/_resource_param_test" 2>/dev/null

echo ""
echo "=================================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
