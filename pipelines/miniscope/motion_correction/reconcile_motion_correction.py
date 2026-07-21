#!/usr/bin/env python
"""Determine which sessions need motion correction.

A CNMF-E model marker (.joblib/.hdf5/.p) counts as proof MC ran even without a
correlation image, because CNMF-E cannot complete without MC's output.

Usage:
    python reconcile_motion_correction.py [--print-output] [--verbose]
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from reconcile_common import (
    ANALYZED_DONE_PATHS,
    collect_marker_dirs,
    is_cnmfe_model,
    is_correlation_image,
    iter_eligible_sessions,
    marker_found,
)


def find_sessions_needing_mc(verbose: bool = False) -> list[tuple[str, str, str]]:
    correlation_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_correlation_image)
    model_dirs = collect_marker_dirs(ANALYZED_DONE_PATHS, is_cnmfe_model)

    needs_mc = []
    for mouse, date, tp in iter_eligible_sessions(verbose=verbose):
        if marker_found(mouse, date, tp, correlation_dirs):
            if verbose:
                print(f"done  {mouse}/{date}/{tp}: correlation image already exists")
            continue

        if marker_found(mouse, date, tp, model_dirs):
            if verbose:
                print(f"done  {mouse}/{date}/{tp}: no correlation image found, but a CNMF-E model exists -- MC must have succeeded")
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
