#!/bin/bash
# One-time (and safely re-runnable) environment bootstrap for a new lab
# member. Run this once by full path, since nothing's on $PATH yet before
# it runs:
#
#   bash $GROUP_HOME/pipelines/current/cli/setup.sh
#
# Idempotent by design: reruns are the intended way to re-check or repair
# your setup later (e.g. if a Sherlock software update moves something this
# pipeline depends on), not just for first-time use. There's no separate
# "verify" command -- running this script again IS the verify/fix step.
#
# Scoped strictly to "become someone who can run pipelines." It does not
# touch git, does not clone anything, does not set up the deploy agent's
# scrontab -- those are separate, smaller-audience concerns (see the
# top-level README's "Adding a new pipeline" / one-time deploy setup
# sections) that most lab members never need to think about.
#
# Manifest-driven, same as cli/run: reads cli/pipelines.yaml (via
# cli/manifest.sh) and checks/wires up every listed pipeline generically,
# rather than hardcoding a block per pipeline here. Adding a third pipeline
# means adding one entry to cli/pipelines.yaml -- this file doesn't need
# to change.

set -uo pipefail  # deliberately not -e: a failed check should still let
                   # later checks run and report, not abort the whole script

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SETUP_DIR/pipelines.yaml"
PIPELINES_ROOT="${PIPELINES_ROOT:-${GROUP_HOME:-$HOME}/pipelines}"
REPO_ROOT="$PIPELINES_ROOT/current"
BASHRC="$HOME/.bashrc"

# shellcheck disable=SC1091
source "$SETUP_DIR/manifest.sh"

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
check "pipeline manifest exists (cli/pipelines.yaml)" '[ -f "$MANIFEST" ]'

echo ""

# --- per-pipeline checks + .bashrc wiring, driven by the manifest ----------

if [ -f "$MANIFEST" ]; then
  while IFS=: read -r p_name p_module p_env_relpath p_env_var p_sif_var; do
    [ -z "$p_name" ] && continue
    case "$p_name" in \#*) continue ;; esac

    env_setup_line="source $REPO_ROOT/$p_env_relpath"

    if [ -e "$PIPELINES_ROOT/current" ]; then
      env_file="$REPO_ROOT/$p_env_relpath"
      if [ -f "$env_file" ]; then
        # Source it in a subshell just to read the container-image var
        # without polluting this script's own environment or re-running
        # its side effects (mkdir, echo) twice.
        eval "$(bash -c "source '$env_file' >/dev/null 2>&1; echo VAL=\$$p_sif_var")"
        check "$p_name container image exists (\$$p_sif_var)" '[ -f "$VAL" ]'
      else
        echo "SKIP - $p_name env_setup.sh not found at $env_file (deploy incomplete?)"
      fi
    fi

    if grep -qF "$env_setup_line" "$BASHRC" 2>/dev/null; then
      echo "PASS - ~/.bashrc already sources $p_name env_setup.sh, nothing to add"
    else
      echo "$env_setup_line" >> "$BASHRC"
      echo "ADDED - appended to ~/.bashrc:"
      echo "    $env_setup_line"
    fi
    echo ""
  done < <(load_pipeline_manifest "$MANIFEST")
fi

# rclone config is shared across every pipeline (same $RCLONE_CONFIG
# default in every env_setup.sh), so it's only worth checking once here
# rather than per-pipeline above.
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
