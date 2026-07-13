#!/bin/bash
# GitOps-style pull-based deploy agent for Sherlock. Intended to run on a
# schedule via `scrontab` (Slurm's own cron, since plain user crontab is
# disabled on Sherlock login nodes) -- see deploy/lab-pipelines.scrontab in
# this same directory for the entry to install with `scrontab -e`.
#
# Why pull, not push: Sherlock's login nodes aren't reachable from the
# internet, so a GitHub webhook has nowhere to deliver to. Instead this
# script periodically checks whether origin has moved, and if so, deploys.
# Same idea as Flux/ArgoCD, scaled down to a scheduled Slurm job for a small lab.
#
# Deploy layout (all under $PIPELINES_ROOT, default ~/pipelines):
#   _repo/            persistent clone, `git fetch` happens here
#   releases/<sha>/   one git worktree per deployed commit (cheap, no re-clone)
#   current -> releases/<sha>/    atomically-flipped symlink every pipeline's
#                                  scripts should resolve their root through
#
# This script itself lives OUTSIDE the release cycle (checked out once,
# manually, not touched by deploys) so a broken commit can never break the
# thing that deploys it.
#
# Per-pipeline sanity checks: after checking out a new commit, this script
# looks for a `deploy_check.sh` at the top of each pipeline directory in the
# new release (e.g. miniscope/deploy_check.sh) and runs it. If a pipeline
# doesn't have one, it's skipped, not failed. The `current` symlink only
# advances if every check that exists passes -- a bad commit just never gets
# promoted, and the next poll will pick up the fix once it's pushed.

set -euo pipefail

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
if ! git worktree -h >/dev/null 2>&1; then
  echo "fatal: git on PATH ($(command -v git), $(git --version)) doesn't support 'git worktree'." >&2
  echo "fatal: run 'module load system git' in this environment, or hardcode its bin/ dir onto PATH here." >&2
  exit 1
fi

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-git@github.com:REPLACE_ME/lab-pipelines.git}"
BRANCH="${BRANCH:-main}"
PIPELINES_ROOT="${PIPELINES_ROOT:-$HOME/pipelines}"

# Cron doesn't source ~/.bashrc, so $SCRATCH may not be set the way it is in
# an interactive shell. Fall back to Sherlock's standard scratch path
# convention, matching every other script in this repo.
SCRATCH="${SCRATCH:-/scratch/users/$(whoami)}"

REPO_DIR="$PIPELINES_ROOT/_repo"
RELEASES_DIR="$PIPELINES_ROOT/releases"
CURRENT_LINK="$PIPELINES_ROOT/current"
KEEP_RELEASES=5

DEPLOY_LOG_DIR="$SCRATCH/logs/deploy"
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
  # Nothing changed. Deliberately silent (no log line) so a 5-minute cron
  # doesn't fill the log with "nothing to do" every run -- only deploy
  # attempts (success or failure) get logged.
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
for pipeline_dir in "$NEW_RELEASE"/*/; do
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
  # Worktree is left in place for inspection; it'll simply be retried on the
  # next poll if a new commit fixes things, or cleaned up by the pruning
  # step below eventually.
  exit 1
fi

# --- atomic promote --------------------------------------------------------

# `ln -sfn` creates the new symlink and swaps it into place as a single
# rename syscall, so nothing reading through $CURRENT_LINK ever observes a
# half-updated state -- it's either the old release or the new one.
ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
log "deploy of $REMOTE_SHA complete, current -> $NEW_RELEASE"

# --- prune old releases ----------------------------------------------------

# Keep the $KEEP_RELEASES most recently checked-out worktrees (by mtime),
# remove the rest via `git worktree remove` so they're cleanly untracked,
# not just rm -rf'd.
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
