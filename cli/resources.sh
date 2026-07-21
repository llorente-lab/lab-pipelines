#!/bin/bash
# Shared resource-estimation helpers for `run`, sourced by cli/run.
# Requires $CLI_DIR and $REPO_ROOT.

RESOURCE_FLAGS=()
_RF_PIPELINE=""
_RF_STAGE=""
_RF_METADATA=()
_RF_EXCLUSIVE=""

_set_resource_flags() {
  _RF_PIPELINE="$1" _RF_STAGE="$2"; shift 2
  _RF_METADATA=("$@")
  _RF_EXCLUSIVE=""
  RESOURCE_FLAGS=()
}

_force_exclusive() {
  _RF_EXCLUSIVE="1"
}

# If the estimator or registry is missing, RESOURCE_FLAGS is left empty and callers
# fall back to the .sbatch file's own #SBATCH defaults.
_apply_resource_overrides() {
  local cores="$1" mem_gb="$2" time="$3"
  RESOURCE_FLAGS=()

  local estimator="$CLI_DIR/estimate_resources.py"
  local registry="$REPO_ROOT/pipelines/$_RF_PIPELINE/resources.yaml"
  if [ ! -f "$estimator" ] || [ ! -f "$registry" ]; then
    return 0
  fi

  local extra=()
  [ -n "$_RF_EXCLUSIVE" ] && extra+=(--exclusive)
  [ -n "$cores" ]  && extra+=(--cores "$cores")
  [ -n "$mem_gb" ] && extra+=(--mem "$mem_gb")
  [ -n "$time" ]   && extra+=(--time "$time")

  mapfile -t RESOURCE_FLAGS < <(
    python3 "$estimator" "$registry" "$_RF_STAGE" \
      ${_RF_METADATA[@]+"${_RF_METADATA[@]}"} "${extra[@]}" 2>/dev/null
  )
}
