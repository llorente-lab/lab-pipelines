#!/bin/bash
# Removes everything test_full_pipeline.sh created. Safe to re-run the test
# from a clean slate afterward.
set -euo pipefail

if [ -z "${MOSEQ_PROJECTS_BASE-}" ]; then
  echo "MOSEQ_PROJECTS_BASE is not set -- source common/env_setup.sh first." >&2
  exit 1
fi

TARGET="$MOSEQ_PROJECTS_BASE/_pipeline_test"
echo "removing $TARGET"
rm -rf "$TARGET"
