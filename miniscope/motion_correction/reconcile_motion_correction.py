#!/usr/bin/env python
"""
Reconcile which sessions need motion correction.

Entry point 1 (standalone): a raw session exists on Drive, and no
correlation_image.npy exists for it anywhere in AnalyzedData (canonical or
archival, checked at both mouse/date/tp and mouse/date depth). This is the
Drive-visible proxy for "MC hasn't run yet", since the mmap itself never
syncs to Drive.

Entry point 2 (from CNMF-E reconciliation) is NOT handled here: it's the case
where a correlation image exists (MC ran at some point) but the mmap has
since aged out of $SCRATCH's ~90-day retention window. That can only be
detected by reconcile_cnmfe.py, which checks scratch directly. Run this
script's output together with `reconcile_cnmfe.py --print-needs-mc` to get
the full MC queue.

Excluded sessions (mice in EXCLUDE_MICE, or found under
Miniscope/AnalyzedData/excluding_for_analysis) are skipped entirely.

Usage:
    python reconcile_motion_correction.py [--print-output] [--verbose]
"""

import argparse
import sys
from pathlib import Path

# reconcile_common.py lives in ../common relative to this file
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from reconcile_common import (
    ANALYZED_DONE_PATHS,
    collect_marker_dirs,
    is_correlation_image,
    iter_eligible_sessions,
    marker_found,
)


def find_sessions_needing_mc(verbose: bool = False) -> list[tuple[str, str, str]]:
    correlation_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_correlation_image)

    needs_mc = []
    for mouse, date, tp in iter_eligible_sessions(verbose=verbose):
        if marker_found(mouse, date, tp, correlation_dirs):
            if verbose:
                print(f"done  {mouse}/{date}/{tp}: correlation image already exists")
            continue

        if verbose:
            print(f"ready {mouse}/{date}/{tp}: needs motion correction")
        needs_mc.append((mouse, date, tp))

    return needs_mc


def main():
    parser = argparse.ArgumentParser(description="Find sessions that need motion correction")
    parser.add_argument("--print-output", action="store_true", help="Print one mouse|date|tp line per session needing MC")
    parser.add_argument("--verbose", action="store_true", help="Print status for every raw session checked")
    args = parser.parse_args()

    sessions = find_sessions_needing_mc(verbose=args.verbose)

    if args.print_output:
        for mouse, date, tp in sessions:
            print(f"{mouse}|{date}|{tp}")
    elif not args.verbose:
        print(len(sessions))


if __name__ == "__main__":
    main()
