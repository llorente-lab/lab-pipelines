#!/bin/bash
# Push one session's AnalyzedData folder from $SCRATCH back to Google Drive.
#
# Usage: sync.sh <mouse> <date> <tp>
#
# Thin wrapper around `run sync` (cli/run's generic rclone-copy command,
# also what `run moseq pull` delegates to) -- this script's only job is
# computing the right src/dest paths and rclone flags for one session, not
# reimplementing the rclone invocation itself.
#
# Uses `copy` semantics, not `sync`: copy only adds/overwrites at the
# destination and never deletes anything there. sync would delete any file on
# Drive not currently present locally, which is too destructive for this use
# case (an incomplete or partially-cleaned local session folder could wipe
# real results off the shared Drive). The tradeoff is that stale/orphaned
# files from partial reruns won't get cleaned up automatically on Drive.
#
# Always excludes *.mmap and *.avi, matching the existing lab convention
# (both are too large to sync routinely; a manual sync is required later if
# someone actually needs the mmap or the motion-corrected video off Sherlock).
# Source the shared env setup first (puts `run` on PATH), so this script is
# self-sufficient whether it's called from pipeline_common.sh, from an
# interactive shell with env_setup.sh already sourced, or completely cold.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_setup.sh"
set -euo pipefail

MOUSE="${1:?Usage: sync.sh <mouse> <date> <tp>}"
DATE="${2:?Usage: sync.sh <mouse> <date> <tp>}"
TP="${3:?Usage: sync.sh <mouse> <date> <tp>}"

MINISCOPE_DRIVE_PREFIX="${MINISCOPE_DRIVE_PREFIX-Miniscope}"
ANALYZED_BASE="${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"

SRC_DIR="$ANALYZED_BASE/$MOUSE/$DATE/$TP"
if [ -n "$MINISCOPE_DRIVE_PREFIX" ]; then
  DEST_DIR="gdrive:${MINISCOPE_DRIVE_PREFIX}/AnalyzedData/$MOUSE/$DATE/$TP"
else
  DEST_DIR="gdrive:AnalyzedData/$MOUSE/$DATE/$TP"
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "SYNC - source directory not found, nothing to sync: $SRC_DIR"
  exit 0
fi

# The sync log lives inside the session's own directory, not a separate
# scratch-wide log tree, so everything about a session -- mmap, correlation
# image, timing log, and now the sync log -- is in one place. It syncs to
# Drive along with everything else next run, which is fine, it's small.
LOG_DIR="$SRC_DIR/logs"
mkdir -p "$LOG_DIR"
SYNC_LOG="$LOG_DIR/sync_$(date +%Y%m%d_%H%M%S).log"

echo "COPY - source:      $SRC_DIR"
echo "COPY - destination: $DEST_DIR"
echo "COPY - log:         $SYNC_LOG"

run sync "$SRC_DIR" "$DEST_DIR" \
  --transfers=8 \
  --checkers=8 \
  --drive-chunk-size=128M \
  --fast-list \
  --exclude="*.mmap" \
  --exclude="*.avi" \
  --ignore-times \
  --log-file="$SYNC_LOG" \
  --log-level=INFO

echo "COPY - completed for $MOUSE/$DATE/$TP"
