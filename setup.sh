#!/bin/bash
# Idempotent environment bootstrap. Run by full path:
#   bash $GROUP_HOME/pipelines/current/setup.sh

set -uo pipefail  # not -e: a failed check shouldn't stop later checks from running

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SETUP_DIR/pipelines.yaml"
PIPELINES_ROOT="${PIPELINES_ROOT:-${GROUP_HOME:-$HOME}/pipelines}"
REPO_ROOT="$PIPELINES_ROOT/current"
BASHRC="$HOME/.bashrc"

# shellcheck disable=SC1091
source "$SETUP_DIR/cli/manifest.sh"

PASS=0
FAIL=0

check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    echo "PASS - $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "checking environment..."
echo ""

check "\$GROUP_HOME is set" '[ -n "${GROUP_HOME-}" ]'
check "\$GROUP_HOME/pipelines is readable (illorent group access)" '[ -r "${GROUP_HOME-/nonexistent}/pipelines" ]'
check "deployed pipeline tree exists (\$PIPELINES_ROOT/current)" '[ -e "$PIPELINES_ROOT/current" ]'
check "apptainer is on \$PATH" 'command -v apptainer >/dev/null 2>&1'
check "pipeline manifest exists (pipelines.yaml)" '[ -f "$MANIFEST" ]'

if command -v module >/dev/null 2>&1; then ##needed
    module load python/3.9.0
    module load system git
else
    echo "WARN - environment modules are unavailable; could not load python/3.9.0 or system git"
fi

echo ""

if [ -f "$MANIFEST" ]; then
  while IFS=: read -r p_name p_module p_env_relpath p_env_var p_sif_var p_resources_yaml; do
    [ -z "$p_name" ] && continue
    case "$p_name" in \#*) continue ;; esac

    env_setup_line="source $REPO_ROOT/$p_env_relpath"

    if [ -e "$PIPELINES_ROOT/current" ]; then
      env_file="$REPO_ROOT/$p_env_relpath"
      if [ -f "$env_file" ]; then
        # Subshell avoids polluting this script's environment with env_setup.sh side effects.
        eval "$(bash -c "source '$env_file' >/dev/null 2>&1; echo VAL=\$$p_sif_var")"
        check "$p_name container image exists (\$$p_sif_var)" '[ -f "$VAL" ]'
      else
        echo "SKIP - $p_name env_setup.sh not found at $env_file (deploy incomplete?)"
      fi
    fi

    # grep -F alone does a substring match, so a COMMENTED-OUT line (e.g.
    # "#source /path/to/env_setup.sh") would still match -- since the
    # commented line contains the target string as a substring -- and
    # falsely report PASS even though it's never actually executed.
    # Filtering out commented lines first avoids that false positive.
    if grep -v '^[[:space:]]*#' "$BASHRC" 2>/dev/null | grep -qF "$env_setup_line"; then
      echo "PASS - ~/.bashrc already sources $p_name env_setup.sh, nothing to add"
    elif grep -qF "$env_setup_line" "$BASHRC" 2>/dev/null; then
      echo "FAIL - ~/.bashrc has a commented-out line for $p_name env_setup.sh -- uncomment it:"
      echo "    $env_setup_line"
      FAIL=$((FAIL + 1))
    else
      echo "$env_setup_line" >> "$BASHRC"
      echo "ADDED - appended to ~/.bashrc:"
      echo "    $env_setup_line"
    fi
    echo ""
  done < <(load_pipeline_manifest "$MANIFEST")
fi

if [ -n "${GROUP_HOME-}" ]; then
  check "rclone config exists (\$GROUP_HOME/rclone/rclone.conf)" '[ -f "$GROUP_HOME/rclone/rclone.conf" ]'
fi

echo ""
echo "checks passed: $PASS, failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Something above needs attention before pipelines will run correctly."
  echo "Most common cause: no illorent group access yet -- ask your PI/sponsor"
  echo "to add you, then rerun this script."
  exit 1
fi

echo ""
echo "Setup complete. Open a new shell (or run: source ~/.bashrc), then try:"
echo "    run list"
echo "    run status"
