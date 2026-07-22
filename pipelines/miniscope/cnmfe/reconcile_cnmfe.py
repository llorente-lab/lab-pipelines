#!/usr/bin/env python
"""Determine which sessions need CNMF-E and which need motion correction first.

Usage:
    python reconcile_cnmfe.py --print-output       # sessions ready for CNMF-E
    python reconcile_cnmfe.py --print-needs-mc      # sessions needing (re-)MC
    python reconcile_cnmfe.py --verbose             # status for every session
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from reconcile_common import (
    ANALYZED_DONE_PATHS,
    collect_marker_dirs,
    find_local_mmap,
    find_local_zip,
    get_scratch_analyzed_base,
    is_cnmfe_model,
    is_roi_zip,
    iter_eligible_sessions,
    marker_found,
)


def find_zip_anywhere(analyzed_base, mouse, date, tp, zip_dirs_on_drive):
    """
    analyzed_base (str): scratch base directory for analyzed data.
    mouse (str): mouse ID.
    date (str): session date.
    tp (str): timepoint.
    zip_dirs_on_drive (set of str): directories already known to have an
        ROI zip, from a Drive listing.

    Returns a bool: whether an ROI zip exists for this session, on Drive
    or locally.
    """
    if marker_found(mouse, date, tp, zip_dirs_on_drive):
        return True
    return find_local_zip(analyzed_base, mouse, date, tp) is not None


def reconcile(verbose=False):
    """
    verbose (bool): print per-session status while reconciling.

    Returns a 3-tuple of lists of (mouse, date, tp) tuples: sessions ready
    for CNMF-E, sessions needing motion correction first, and sessions
    still waiting on an ROI zip.
    """
    analyzed_base = get_scratch_analyzed_base()

    model_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_cnmfe_model)
    zip_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_roi_zip)

    ready_for_cnmfe = []
    needs_mc = []
    waiting_on_roi = []

    for mouse, date, tp in iter_eligible_sessions(verbose=verbose):
        if marker_found(mouse, date, tp, model_dirs):
            if verbose:
                print(f"done  {mouse}/{date}/{tp}: CNMF-E model already exists (.joblib/.hdf5/.p)")
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
