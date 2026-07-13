#!/usr/bin/env python
"""
Reconcile which sessions need CNMF-E, and which sessions CNMF-E has
discovered need motion correction (re-)done first.

Per session, the checks run in this order:

  1. Is there already a .joblib on Drive (canonical or archival, either
     directory depth)? If so, done, skip entirely.
  2. Is there an ROI .zip? Checked on both Drive and scratch, since a
     labmate may have uploaded it straight to Drive without it ever
     touching scratch. If missing, this session is waiting on a human to
     finish FIJI segmentation, not an error, just not ready yet.
  3. Is the mmap actually live on $SCRATCH right now? If yes, this session
     is ready for CNMF-E. If no, despite zip + (possibly) an old
     correlation image existing, the mmap has aged out of scratch's
     ~90-day retention and this session needs motion correction run again.
     This is CNMF-E reconciliation's entry point into the MC queue.

Usage:
    python reconcile_cnmfe.py --print-output       # sessions ready for CNMF-E
    python reconcile_cnmfe.py --print-needs-mc      # sessions needing (re-)MC
    python reconcile_cnmfe.py --verbose             # status for every session
"""

import argparse
import sys
from pathlib import Path

# reconcile_common.py lives in ../common relative to this file
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from reconcile_common import (
    ANALYZED_DONE_PATHS,
    collect_marker_dirs,
    find_local_mmap,
    find_local_zip,
    get_scratch_analyzed_base,
    is_joblib,
    is_roi_zip,
    iter_eligible_sessions,
    marker_found,
)


def find_zip_anywhere(analyzed_base: str, mouse: str, date: str, tp: str, zip_dirs_on_drive: set[str]) -> bool:
    if marker_found(mouse, date, tp, zip_dirs_on_drive):
        return True
    return find_local_zip(analyzed_base, mouse, date, tp) is not None


def reconcile(verbose: bool = False):
    analyzed_base = get_scratch_analyzed_base()

    joblib_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_joblib)
    zip_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_roi_zip)

    ready_for_cnmfe = []
    needs_mc = []
    waiting_on_roi = []

    for mouse, date, tp in iter_eligible_sessions(verbose=verbose):
        if marker_found(mouse, date, tp, joblib_dirs):
            if verbose:
                print(f"done  {mouse}/{date}/{tp}: joblib already exists")
            continue

        if not find_zip_anywhere(analyzed_base, mouse, date, tp, zip_dirs):
            if verbose:
                print(f"wait  {mouse}/{date}/{tp}: no ROI zip yet")
            waiting_on_roi.append((mouse, date, tp))
            continue

        if find_local_mmap(analyzed_base, mouse, date, tp) is not None:
            if verbose:
                print(f"ready {mouse}/{date}/{tp}: mmap live on scratch, ready for CNMF-E")
            ready_for_cnmfe.append((mouse, date, tp))
        else:
            if verbose:
                print(f"mc    {mouse}/{date}/{tp}: zip present but mmap missing/expired, needs motion correction")
            needs_mc.append((mouse, date, tp))

    return ready_for_cnmfe, needs_mc, waiting_on_roi


def main():
    parser = argparse.ArgumentParser(description="Find sessions ready for CNMF-E, and sessions that need MC first")
    parser.add_argument("--print-output", action="store_true", help="Print mouse|date|tp lines for sessions ready for CNMF-E")
    parser.add_argument("--print-needs-mc", action="store_true", help="Print mouse|date|tp lines for sessions needing motion correction")
    parser.add_argument("--verbose", action="store_true", help="Print status for every session checked")
    args = parser.parse_args()

    ready_for_cnmfe, needs_mc, waiting_on_roi = reconcile(verbose=args.verbose)

    if args.print_output:
        for mouse, date, tp in ready_for_cnmfe:
            print(f"{mouse}|{date}|{tp}")
    elif args.print_needs_mc:
        for mouse, date, tp in needs_mc:
            print(f"{mouse}|{date}|{tp}")
    elif not args.verbose:
        print(f"ready for CNMF-E: {len(ready_for_cnmfe)}")
        print(f"needs motion correction: {len(needs_mc)}")
        print(f"waiting on ROI: {len(waiting_on_roi)}")


if __name__ == "__main__":
    main()
