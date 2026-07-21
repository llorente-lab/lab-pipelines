#!/bin/bash
# GitOps-style pull-based deploy agent for Sherlock. Intended to run on a
# schedule via `scrontab` (Slurm's own cron, since plain user crontab is
# disabled on Sherlock login nodes) -- see deploy/lab-pipelines.scrontab in
# this same directory for the entry to install with `scrontab -e`.

set -euo pipefail

GIT_MODULE_BIN="/share/software/user/open/git/2.45.1/bin"
PYTHON_MODULE_BIN="/share/software/user/open/python/3.9.0/bin"
[ -d "$GIT_MODULE_BIN" ] && PATH="$GIT_MODULE_BIN:$PATH"
[ -d "$PYTHON_MODULE_BIN" ] && PATH="$PYTHON_MODULE_BIN:$PATH"

# Still try `module load` too (belt and suspenders, e.g. if the hardcoded
# path above ever goes stale after a Sherlock software update), but no
# longer depend on it for correctness.
if ! type module >/dev/null 2>&1; then
  for lmod_init in /etc/profile.d/lmod.sh /etc/profile.d/z00_lmod.sh \
                   /share/software/lmod/lmod/init/bash; do
    [ -f "$lmod_init" ] && source "$lmod_init" && break
  done
fi
if type module >/dev/null 2>&1; then
  module load system git >/dev/null 2>&1 || true
  module load python/3.9.0 >/dev/null 2>&1 || true
fi

GIT_VERSION="$(git --version | awk '{print $3}')"
MIN_GIT_VERSION="2.20"
if [ "$(printf '%s\n%s\n' "$MIN_GIT_VERSION" "$GIT_VERSION" | sort -V | head -n1)" != "$MIN_GIT_VERSION" ]; then
  echo "fatal: git on PATH ($(command -v git), version $GIT_VERSION) is older than $MIN_GIT_VERSION, missing 'git worktree'/'-C' support." >&2
  echo "fatal: expected a modern git at $GIT_MODULE_BIN -- check it still exists (Sherlock software may have updated) and update GIT_MODULE_BIN above if the version changed." >&2
  exit 1
fi

# config

REPO_URL="${REPO_URL:-git@github.com:REPLACE_ME/lab-pipelines.git}"
BRANCH="${BRANCH:-main}"

# $GROUP_HOME is shared, backed up, and never purged 
PIPELINES_ROOT="${PIPELINES_ROOT:-${GROUP_HOME:-$HOME}/pipelines}"

# Cron doesn't source ~/.bashrc
SCRATCH="${SCRATCH:-/scratch/users/$(whoami)}"

REPO_DIR="$PIPELINES_ROOT/_repo"
RELEASES_DIR="$PIPELINES_ROOT/releases"
CURRENT_LINK="$PIPELINES_ROOT/current"
KEEP_RELEASES=5

# Deploy history is small text
DEPLOY_LOG_DIR="$PIPELINES_ROOT/logs/deploy"
mkdir -p "$DEPLOY_LOG_DIR" "$RELEASES_DIR"
DEPLOY_LOG="$DEPLOY_LOG_DIR/deploy.log"

log() {
  echo "$(date -Iseconds) $*" | tee -a "$DEPLOY_LOG"
}

# --- fetch ---------------------------------------------------------------

if [ ! -d "$REPO_DIR/.git" ]; then
  log "bootstrap: cloning $REPO_URL into $REPO_DIR"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
REMOTE_SHA="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"

CURRENT_SHA="none"
if [ -L "$CURRENT_LINK" ]; then
  CURRENT_SHA="$(basename "$(readlink -f "$CURRENT_LINK")" 2>/dev/null || echo none)"
fi

if [ "$REMOTE_SHA" = "$CURRENT_SHA" ]; then
  exit 0
fi

log "deploying $REMOTE_SHA (was $CURRENT_SHA)"

# --- checkout a fresh worktree for this commit --------------------------

NEW_RELEASE="$RELEASES_DIR/$REMOTE_SHA"
if [ ! -d "$NEW_RELEASE" ]; then
  git -C "$REPO_DIR" worktree add --detach --quiet "$NEW_RELEASE" "$REMOTE_SHA"
fi

# --- per-pipeline sanity checks -------------------------------------------

CHECK_FAILURES=0
# Checked at two levels
for pipeline_dir in "$NEW_RELEASE"/*/ "$NEW_RELEASE"/pipelines/*/; do
  [ -d "$pipeline_dir" ] || continue
  pipeline_name="$(basename "$pipeline_dir")"
  check_script="$pipeline_dir/deploy_check.sh"
  if [ -f "$check_script" ]; then
    log "check: running $pipeline_name/deploy_check.sh"
    if bash "$check_script" >> "$DEPLOY_LOG" 2>&1; then
      log "check: $pipeline_name passed"
    else
      log "check: $pipeline_name FAILED"
      CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
  fi
done

if [ "$CHECK_FAILURES" -gt 0 ]; then
  log "deploy of $REMOTE_SHA aborted: $CHECK_FAILURES check(s) failed, current symlink left unchanged"
  exit 1
fi
ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
log "deploy of $REMOTE_SHA complete, current -> $NEW_RELEASE"

# prune old releases
mapfile -t OLD_RELEASES < <(
  ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | tail -n +"$((KEEP_RELEASES + 1))"
)
for old in "${OLD_RELEASES[@]:-}"; do
  [ -z "$old" ] && continue
  old="${old%/}"
  [ "$old" = "$NEW_RELEASE" ] && continue
  log "pruning old release: $old"
  git -C "$REPO_DIR" worktree remove --force "$old" 2>>"$DEPLOY_LOG" || rm -rf "$old"
done
