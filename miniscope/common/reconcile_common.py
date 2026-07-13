#!/usr/bin/env python
"""
Shared helpers for reconciliation: figuring out which sessions need motion
correction and which need CNMF-E, per the contract worked out for this pipeline.

Key design points this file encodes (see the pipeline design discussion for why):

  - MC-done is checked via Drive, looking for correlation_image.npy, NOT the
    mmap itself, since the mmap is permanently excluded from every rclone sync
    and can never be detected from Drive.

  - CNMF-E-done is checked via Drive, looking for a .joblib file. If it's
    there, the session is finished, full stop, don't touch it.

  - AnalyzedData lives across four Drive locations:
        canonical:  Miniscope/AnalyzedData
        archival:   Miniscope/AnalyzedData/old_processed_by_Atharv
                    Miniscope/AnalyzedData/reorganized_and_reprocessed
        excluded:   Miniscope/AnalyzedData/excluding_for_analysis
    Canonical and archival count identically for "is this done" checks.
    Excluded means skip the session entirely, don't even evaluate it.

  - Every AnalyzedData lookup is done at both mouse/date/tp AND mouse/date,
    since older sessions predate the tp-level directory convention.

  - CNMF-E readiness (zip present + mmap present) is checked against
    $SCRATCH, not Drive, since the mmap can only ever be verified locally,
    and scratch has a ~90-day retention window, so "MC happened once" and
    "the mmap is available right now" are different facts.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

# Real mouse IDs all follow this convention (matches the validation the old
# bash pipeline did with `[[ "$MOUSE" =~ ^VK_ ]]`). Needed because RawData on
# Drive isn't purely session data, e.g. a CaImAn repo clone and a stray
# "tests" folder happen to also be exactly three levels deep, indistinguishable
# from mouse/date/tp by directory depth alone.
MOUSE_NAME_PATTERN = re.compile(r"^VK_")

GDRIVE_REMOTE = "gdrive"

# If the rclone remote's root_folder_id is set to Drive's root (or any folder
# ABOVE Miniscope), leave this as "Miniscope". If root_folder_id is instead set
# to the Miniscope folder itself, set MINISCOPE_DRIVE_PREFIX="" (via env var)
# so gdrive: already means Miniscope/ and paths don't get doubled up.
MINISCOPE_DRIVE_PREFIX = os.environ.get("MINISCOPE_DRIVE_PREFIX", "Miniscope")


def gdrive_path(*parts: str) -> str:
    """Build a gdrive: remote path, inserting MINISCOPE_DRIVE_PREFIX if set."""
    segments = [p for p in ([MINISCOPE_DRIVE_PREFIX] + list(parts)) if p]
    return f"{GDRIVE_REMOTE}:" + "/".join(segments)


RAW_BASE = gdrive_path("RawData")
ANALYZED_CANONICAL = gdrive_path("AnalyzedData")
ANALYZED_ARCHIVAL = [
    gdrive_path("AnalyzedData", "old_processed_by_Atharv"),
    gdrive_path("AnalyzedData", "reorganized_and_reprocessed"),
]
ANALYZED_EXCLUDED = gdrive_path("AnalyzedData", "excluding_for_analysis")
ANALYZED_DONE_PATHS = [ANALYZED_CANONICAL] + ANALYZED_ARCHIVAL

# Mice to skip regardless of what Drive says. Mirrors the old hardcoded
# EXCLUDE set in reconcile_cnmfe_sessions.py; kept here so both MC and
# CNMF-E reconciliation share one list instead of drifting independently.
EXCLUDE_MICE = {
    "VK_20250408_a",
    "VK_20250407_a",
    "VK_20250408_b",
    "VK_20250416_b",
    "VK_20250416_a",
    "VK_20250617_a",
    "VK_20250617_b",
    "VK_20250220_c",
    "VK_20250730_c",
    "VK_20250729_d",
    "VK_20250729_b",
    "VK_20250616_a",
    "VK_20250616_b",
    "VK_20250410_b",
    "VK_20250416_c",
    "VK_20250416_d",
}


def get_scratch_analyzed_base() -> str:
    scratch = os.environ.get("SCRATCH", f"/scratch/users/{os.environ.get('USER', 'unknown')}")
    return f"{scratch}/Miniscope/AnalyzedData"


# ---------------------------------------------------------------------------
# rclone wrappers
# ---------------------------------------------------------------------------

def rclone_list_files(remote_path: str) -> list[str]:
    """All file paths under remote_path, recursively, relative to remote_path. [] if missing/empty."""
    result = subprocess.run(
        ["rclone", "lsf", "-R", "--files-only", remote_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def rclone_list_dirs(remote_path: str, max_depth: int | None = None) -> list[str]:
    """All directory paths under remote_path, relative to remote_path. [] if missing/empty."""
    cmd = ["rclone", "lsf", "-R", "--dirs-only", remote_path]
    if max_depth is not None:
        cmd.insert(2, f"--max-depth={max_depth}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line.strip().rstrip("/") for line in result.stdout.splitlines() if line.strip()]


# ---------------------------------------------------------------------------
# Session discovery
# ---------------------------------------------------------------------------

def discover_raw_sessions() -> list[tuple[str, str, str]]:
    """
    List every (mouse, date, tp) triple that exists under RawData on Drive.
    A session is any directory exactly three levels deep under RawData.
    """
    dirs = rclone_list_dirs(RAW_BASE, max_depth=3)
    sessions = []
    for d in dirs:
        parts = d.split("/")
        if len(parts) == 3:
            mouse, date, tp = parts
            if not MOUSE_NAME_PATTERN.match(mouse):
                continue
            sessions.append((mouse, date, tp))
    return sessions


def get_excluded_mice_from_drive() -> set[str]:
    """
    Mice found at all under excluding_for_analysis are treated as fully excluded,
    regardless of which date/tp specifically triggered that.
    """
    top_level_dirs = rclone_list_dirs(ANALYZED_EXCLUDED, max_depth=1)
    return {d.split("/")[0] for d in top_level_dirs if d}


def all_excluded_mice() -> set[str]:
    return EXCLUDE_MICE | get_excluded_mice_from_drive()


def iter_eligible_sessions(verbose: bool = False):
    """
    Shared discovery shell for both reconciliation scripts: discover raw
    sessions, drop excluded mice, yield the rest as (mouse, date, tp).
    Each caller's main() only needs to implement its own done/ready logic on
    top of this, not re-derive session discovery + exclusion filtering.
    """
    raw_sessions = discover_raw_sessions()
    excluded_mice = all_excluded_mice()

    for mouse, date, tp in sorted(raw_sessions):
        if mouse in excluded_mice:
            if verbose:
                print(f"skip  {mouse}/{date}/{tp}: excluded mouse")
            continue
        yield mouse, date, tp


# ---------------------------------------------------------------------------
# Drive-based "done" marker lookups
# ---------------------------------------------------------------------------

def collect_marker_dirs(base_paths: list[str], filename_matches) -> set[str]:
    """
    Scan each base_path for files matching filename_matches(filename) -> bool,
    and return the set of containing directories (relative, POSIX-style,
    'mouse/date' or 'mouse/date/tp') across all base_paths combined.
    """
    found_dirs = set()
    for base in base_paths:
        for rel_file in rclone_list_files(base):
            parts = rel_file.split("/")
            fname = parts[-1]
            if filename_matches(fname):
                dir_parts = parts[:-1]
                if len(dir_parts) >= 2:
                    found_dirs.add("/".join(dir_parts))
    return found_dirs


def is_correlation_image(fname: str) -> bool:
    return fname.lower().endswith(".npy") and "correlation_image" in fname.lower()


def is_joblib(fname: str) -> bool:
    return fname.lower().endswith(".joblib")


def is_roi_zip(fname: str) -> bool:
    return fname.lower().endswith(".zip")


def session_dir_variants(mouse: str, date: str, tp: str) -> list[str]:
    """Both directory depths worth checking, tp-level first."""
    return [f"{mouse}/{date}/{tp}", f"{mouse}/{date}"]


def marker_found(mouse: str, date: str, tp: str, marker_dirs: set[str]) -> bool:
    return any(v in marker_dirs for v in session_dir_variants(mouse, date, tp))


# ---------------------------------------------------------------------------
# Scratch-based (local filesystem) lookups -- these are the ones that can
# never be answered from Drive (mmap), or that need to reflect what's
# actually on disk right now rather than what once synced (90-day retention).
# ---------------------------------------------------------------------------

def scratch_candidates(analyzed_base: str, mouse: str, date: str, tp: str) -> list[Path]:
    return [Path(analyzed_base) / mouse / date / tp, Path(analyzed_base) / mouse / date]


def find_local_mmap(analyzed_base: str, mouse: str, date: str, tp: str) -> Path | None:
    for candidate in scratch_candidates(analyzed_base, mouse, date, tp):
        if not candidate.exists():
            continue
        for f in candidate.rglob("*.mmap"):
            if "order_c" in f.name.lower():
                return f
    return None


def find_local_zip(analyzed_base: str, mouse: str, date: str, tp: str) -> Path | None:
    for candidate in scratch_candidates(analyzed_base, mouse, date, tp):
        if not candidate.exists():
            continue
        for f in candidate.rglob("*.zip"):
            return f
    return None
