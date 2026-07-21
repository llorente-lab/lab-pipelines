#!/bin/bash
# Shared resource-estimation helpers for `run`. Sourced by cli/run so
# _set_resource_flags is available to every pipeline module (cli/pipelines/*.sh).
#
# _set_resource_flags <pipeline> <stage> [key=value ...]
#
#   Reads pipelines/<pipeline>/resources.yaml via estimate_resources.py,
#   evaluates the formula for the given stage with any supplied metadata
#   key=value pairs, clamps to registry min/max, falls back to registry
#   fallback when metadata is missing or formula evaluation fails.
#
#   Sets global RESOURCE_FLAGS array, ready to splice into sbatch:
#     _set_resource_flags miniscope motion-correction "n_sessions=1"
#     sbatch ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ...
#
#   If estimate_resources.py or the registry is missing, RESOURCE_FLAGS is set
#   empty -- callers fall back to whatever #SBATCH defaults remain in the script.
#
# Requires $CLI_DIR and $REPO_ROOT to be set (cli/run sets both before sourcing).

RESOURCE_FLAGS=()

_set_resource_flags() {
  local pipeline="$1" stage="$2"; shift 2
  RESOURCE_FLAGS=()

  local estimator="$CLI_DIR/estimate_resources.py"
  local registry="$REPO_ROOT/pipelines/$pipeline/resources.yaml"
  if [ ! -f "$estimator" ] || [ ! -f "$registry" ]; then
    return 0
  fi

  local estimates
  estimates="$(python3 "$estimator" "$registry" "$stage" "$@" 2>/dev/null)" || true
  if [ -z "$estimates" ]; then
    return 0
  fi

  unset ESTIMATED_PARTITION ESTIMATED_CORES ESTIMATED_MEM_GB ESTIMATED_EXCLUSIVE ESTIMATED_QOS
  eval "$estimates" 2>/dev/null || true

  if [ -n "${ESTIMATED_PARTITION:-}" ];                      then RESOURCE_FLAGS+=("--partition=$ESTIMATED_PARTITION"); fi
  if [ -n "${ESTIMATED_CORES:-}" ];                          then RESOURCE_FLAGS+=("--cpus-per-task=$ESTIMATED_CORES"); fi
  if [ -n "${ESTIMATED_MEM_GB:-}" ];                        then RESOURCE_FLAGS+=("--mem=${ESTIMATED_MEM_GB}G"); fi
  if [ "${ESTIMATED_EXCLUSIVE:-false}" = "true" ];           then RESOURCE_FLAGS+=("--exclusive"); fi
  # Only ever set when resources.yaml names one explicitly for this stage
  # (see estimate_resources.py's header) -- e.g. a stage whose --time
  # exceeds the account's default QOS MaxWall and genuinely needs a higher
  # one. Not emitted otherwise, so every other stage keeps using Sherlock's
  # own default QOS with no override.
  if [ -n "${ESTIMATED_QOS:-}" ];                            then RESOURCE_FLAGS+=("--qos=$ESTIMATED_QOS"); fi
}

# Call after _set_resource_flags to override with a whole-node request --
# e.g. a genuinely huge dataset where it's worth reserving all of illorent
# (a single node) for one expensive run, rather than the cores/mem numbers
# resources.yaml calibrated for a typical run of that stage. Strips any
# --cpus-per-task/--mem already in RESOURCE_FLAGS (second-guessing an
# explicit whole-node request with a typical-run number would be
# self-defeating -- Slurm hands the job everything the node has instead)
# and ensures --exclusive is present exactly once.
#
# Usage:
#   _set_resource_flags miniscope motion-correction "n_sessions=1"
#   [ "$want_exclusive" = "1" ] && _force_exclusive
_force_exclusive() {
  local flag kept=()
  for flag in ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"}; do
    case "$flag" in
      --cpus-per-task=*|--mem=*|--exclusive) continue ;;
      *) kept+=("$flag") ;;
    esac
  done
  kept+=("--exclusive")
  RESOURCE_FLAGS=("${kept[@]}")
}

# Call after _set_resource_flags (and after _force_exclusive, if used) to
# apply explicit per-invocation overrides for cores/mem/wall time -- e.g.
# someone who knows their specific run needs more than resources.yaml's
# calibrated-for-typical-runs number. Any argument left empty ("") is not
# overridden, whatever's already in RESOURCE_FLAGS (or nothing, if
# _force_exclusive already stripped it) stands. These are applied LAST,
# after _force_exclusive, and always win even in combination with
# --exclusive -- if someone explicitly asks for --exclusive AND a specific
# --cores, that's a deliberate, unusual combination (a whole node, but
# still telling Slurm to book only part of it for this job), not
# something to silently override in either direction.
#
# --time has no registry equivalent at all today (resources.yaml/
# estimate_resources.py don't estimate wall time, see the discussion in
# past sessions) -- this is currently the ONLY way to change a stage's
# wall time short of editing its .sbatch file's #SBATCH --time directive.
#
# Usage:
#   _set_resource_flags miniscope motion-correction "n_sessions=1"
#   [ -n "$want_exclusive" ] && _force_exclusive
#   _apply_resource_overrides "$cores" "$mem_gb" "$time"
_apply_resource_overrides() {
  local cores="$1" mem_gb="$2" time="$3"
  local flag kept=()
  for flag in ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"}; do
    case "$flag" in
      --cpus-per-task=*) [ -n "$cores" ] && continue ;;
      --mem=*)           [ -n "$mem_gb" ] && continue ;;
      --time=*)          [ -n "$time" ] && continue ;;
    esac
    kept+=("$flag")
  done
  [ -n "$cores" ]  && kept+=("--cpus-per-task=$cores")
  [ -n "$mem_gb" ] && kept+=("--mem=${mem_gb}G")
  [ -n "$time" ]   && kept+=("--time=$time")
  RESOURCE_FLAGS=("${kept[@]}")
}
