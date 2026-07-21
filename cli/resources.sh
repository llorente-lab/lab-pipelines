#!/bin/bash
# Shared resource-estimation helpers for `run`. Sourced by cli/run so
# _set_resource_flags is available to every pipeline module (cli/pipelines/*.sh).
#
# _set_resource_flags <pipeline> <stage> [key=value ...]
#
#   Reads <pipeline>/resources.yaml via estimate_resources.py, evaluates the
#   formula for the given stage with any supplied metadata key=value pairs,
#   clamps to registry min/max, falls back to registry fallback when metadata
#   is missing or formula evaluation fails.
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
  local registry="$REPO_ROOT/$pipeline/resources.yaml"
  [ -f "$estimator" ] && [ -f "$registry" ] || return

  local estimates
  estimates="$(python3 "$estimator" "$registry" "$stage" "$@" 2>/dev/null)" || true
  [ -z "$estimates" ] && return

  unset ESTIMATED_PARTITION ESTIMATED_CORES ESTIMATED_MEM_GB ESTIMATED_EXCLUSIVE
  eval "$estimates" 2>/dev/null || true

  [ -n "${ESTIMATED_PARTITION:-}" ]  && RESOURCE_FLAGS+=("--partition=$ESTIMATED_PARTITION")
  [ -n "${ESTIMATED_CORES:-}" ]      && RESOURCE_FLAGS+=("--cpus-per-task=$ESTIMATED_CORES")
  [ -n "${ESTIMATED_MEM_GB:-}" ]     && RESOURCE_FLAGS+=("--mem=${ESTIMATED_MEM_GB}G")
  [ "${ESTIMATED_EXCLUSIVE:-false}" = "true" ] && RESOURCE_FLAGS+=("--exclusive")
}
