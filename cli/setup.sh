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

set -uo pipefail  # deliberately not -e: a failed check should still let
                   # later checks run and report, not abort the whole script

PIPELINES_ROOT="${PIPELINES_ROOT:-${GROUP_HOME:-$HOME}/pipelines}"
MINISCOPE_ENV_SETUP_LINE="source $PIPELINES_ROOT/current/miniscope/common/env_setup.sh"
MOSEQ_ENV_SETUP_LINE="source $PIPELINES_ROOT/current/moseq/common/env_setup.sh"
BASHRC="$HOME/.bashrc"

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

if [ -e "$PIPELINES_ROOT/current" ]; then
  ENV_FILE="$PIPELINES_ROOT/current/miniscope/common/env_setup.sh"
  if [ -f "$ENV_FILE" ]; then
    # Source it in a subshell just to read SIF/RCLONE_CONFIG without
    # polluting this script's own environment or re-running its side effects
    # (mkdir, echo) twice.
    eval "$(bash -c "source '$ENV_FILE' >/dev/null 2>&1; echo SIF=\$SIF; echo RCLONE_CONFIG=\$RCLONE_CONFIG")"
    check "miniscope container image exists (\$SIF)" '[ -f "$SIF" ]'
    check "rclone config exists (\$RCLONE_CONFIG)" '[ -f "$RCLONE_CONFIG" ]'
  fi

  MOSEQ_ENV_FILE="$PIPELINES_ROOT/current/moseq/common/env_setup.sh"
  if [ -f "$MOSEQ_ENV_FILE" ]; then
    eval "$(bash -c "source '$MOSEQ_ENV_FILE' >/dev/null 2>&1; echo MOSEQ_SIF=\$MOSEQ_SIF")"
    check "moseq container image exists (\$MOSEQ_SIF)" '[ -f "$MOSEQ_SIF" ]'
  fi
fi

echo ""

# --- wire up .bashrc, idempotently --------------------------------------

if grep -qF "$MINISCOPE_ENV_SETUP_LINE" "$BASHRC" 2>/dev/null; then
  echo "PASS - ~/.bashrc already sources miniscope env_setup.sh, nothing to add"
else
  echo "$MINISCOPE_ENV_SETUP_LINE" >> "$BASHRC"
  echo "ADDED - appended to ~/.bashrc:"
  echo "    $MINISCOPE_ENV_SETUP_LINE"
fi

if grep -qF "$MOSEQ_ENV_SETUP_LINE" "$BASHRC" 2>/dev/null; then
  echo "PASS - ~/.bashrc already sources moseq env_setup.sh, nothing to add"
else
  echo "$MOSEQ_ENV_SETUP_LINE" >> "$BASHRC"
  echo "ADDED - appended to ~/.bashrc:"
  echo "    $MOSEQ_ENV_SETUP_LINE"
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
