#!/usr/bin/env python
"""Shared helpers for MC and CNMF-E session reconciliation."""

import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path

# Short-lived disk cache for `rclone lsf -R` results. Caching by remote path (with a short TTL, not indefinite --
# Drive state does change) turns the second+ scan of the same path into a
# local file read instead of another traversal.
_CACHE_DIR = Path(
    os.environ.get("MINISCOPE_RECONCILE_CACHE_DIR")
    or f"{os.environ.get('SCRATCH', '/tmp')}/Miniscope/.reconcile_cache"
)
_CACHE_TTL_S = int(os.environ.get("MINISCOPE_RECONCILE_CACHE_TTL_S", "500"))


def _cache_key(*parts):
    """
    parts (str): pieces to combine into a cache key.

    Returns the Path of the cache file for this key.
    """
    digest = hashlib.sha1("|".join(parts).encode()).hexdigest()
    return _CACHE_DIR / f"{digest}.json"


def _cached(key_parts, compute):
    """
    Return compute()'s result, cached under key_parts for _CACHE_TTL_S
    seconds. Any cache read/write failure (missing dir, race, corrupt
    file) falls back to just calling compute() -- caching is a speed
    optimization, never a correctness requirement.

    key_parts (tuple of str): pieces to combine into a cache key.
    compute (callable): zero-arg function producing the value to cache.
    """
    path = _cache_key(*key_parts)
    try:
        if path.exists() and (time.time() - path.stat().st_mtime) < _CACHE_TTL_S:
            return json.loads(path.read_text())
    except Exception:
        pass
    result = compute()
    try:
        _CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result))
    except Exception:
        pass
    return result

# RawData on Drive also contains non-session dirs (repo clones, stray folders) at the same depth,
# so we filter by mouse name pattern rather than relying on directory depth alone.
MOUSE_NAME_PATTERN = re.compile(r"^VK_")

GDRIVE_REMOTE = "gdrive"

# Set MINISCOPE_DRIVE_PREFIX="" if the rclone remote's root_folder_id points
MINISCOPE_DRIVE_PREFIX = os.environ.get("MINISCOPE_DRIVE_PREFIX", "Miniscope")


def gdrive_path(*parts):
    """
    Build a gdrive: remote path, inserting MINISCOPE_DRIVE_PREFIX if set.

    parts (str): path segments to join after the prefix.

    Returns a str, the full gdrive: remote path.
    """
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


def get_scratch_analyzed_base():
    """Returns a str, the scratch path where analyzed Miniscope data lives."""
    scratch = os.environ.get("SCRATCH", f"/scratch/users/{os.environ.get('USER', 'unknown')}")
    return f"{scratch}/Miniscope/AnalyzedData"


def _rclone_list_files_uncached(remote_path):
    """remote_path (str): rclone remote path to list. Returns a list of str."""
    result = subprocess.run(
        ["rclone", "lsf", "-R", "--files-only", remote_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def rclone_list_files(remote_path):
    """
    All file paths under remote_path recursively, relative to remote_path.
    Cached (see _cached above) since multiple reconcile calls scan the same
    remote paths within one `run queue`/`run miniscope dashboard` call.

    remote_path (str): rclone remote path to list.

    Returns a list of str.
    """
    return _cached(("files", remote_path), lambda: _rclone_list_files_uncached(remote_path))


def _rclone_list_dirs_uncached(remote_path, max_depth):
    """
    remote_path (str): rclone remote path to list.
    max_depth (int or None): passed to rclone's --max-depth, or unlimited
        if None.

    Returns a list of str.
    """
    cmd = ["rclone", "lsf", "-R", "--dirs-only", remote_path]
    if max_depth is not None:
        cmd.insert(2, f"--max-depth={max_depth}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line.strip().rstrip("/") for line in result.stdout.splitlines() if line.strip()]


def rclone_list_dirs(remote_path, max_depth=None):
    """
    All directory paths under remote_path, relative to remote_path.
    Cached, see rclone_list_files.

    remote_path (str): rclone remote path to list.
    max_depth (int or None): passed to rclone's --max-depth.

    Returns a list of str.
    """
    return _cached(
        ("dirs", remote_path, str(max_depth)),
        lambda: _rclone_list_dirs_uncached(remote_path, max_depth),
    )


def discover_raw_sessions():
    """
    List every (mouse, date, tp) triple under RawData on Drive.

    Returns a list of (str, str, str) tuples.
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


def get_excluded_mice_from_drive():
    """Returns a set of str: mice found under excluding_for_analysis on Drive."""
    top_level_dirs = rclone_list_dirs(ANALYZED_EXCLUDED, max_depth=1)
    return {d.split("/")[0] for d in top_level_dirs if d}


def all_excluded_mice():
    """Returns a set of str: the hardcoded EXCLUDE_MICE plus Drive-excluded mice."""
    return EXCLUDE_MICE | get_excluded_mice_from_drive()


def iter_eligible_sessions(verbose=False):
    """
    Yield (mouse, date, tp) for all raw sessions after filtering excluded
    mice.

    verbose (bool): print each skipped session.
    """
    raw_sessions = discover_raw_sessions()
    excluded_mice = all_excluded_mice()

    for mouse, date, tp in sorted(raw_sessions):
        if mouse in excluded_mice:
            if verbose:
                print(f"skip  {mouse}/{date}/{tp}: excluded mouse")
            continue
        yield mouse, date, tp


def collect_marker_dirs(base_paths, filename_matches):
    """
    Scan each base_path for files matching filename_matches(filename), and
    return the set of containing directories (relative, POSIX-style,
    'mouse/date' or 'mouse/date/tp') across all base_paths combined.

    base_paths (list of str): remote paths to scan.
    filename_matches (callable): takes a filename (str), returns a bool.

    Returns a set of str.
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


def is_correlation_image(fname):
    """
    fname (str): filename to check.

    Returns a bool. Some archival sessions only synced the PNG
    visualization, not the .npy -- both count as evidence MC ran.
    """
    name = fname.lower()
    return "correlation_image" in name and (name.endswith(".npy") or name.endswith(".png"))


def is_cnmfe_model(fname):
    """
    fname (str): filename to check.

    Returns a bool. Archival sessions may only have .hdf5 or .p with no
    .joblib; all three count as done.
    """
    name = fname.lower()
    return name.endswith(".joblib") or name.endswith(".hdf5") or name.endswith(".p")


def is_roi_zip(fname):
    """fname (str): filename to check. Returns a bool."""
    return fname.lower().endswith(".zip")


def session_dir_variants(mouse, date, tp):
    """
    Both directory depths worth checking, tp-level first.

    mouse (str): mouse ID.
    date (str): session date.
    tp (str): timepoint.

    Returns a list of str.
    """
    return [f"{mouse}/{date}/{tp}", f"{mouse}/{date}"]


def marker_found(mouse, date, tp, marker_dirs):
    """
    mouse (str): mouse ID.
    date (str): session date.
    tp (str): timepoint.
    marker_dirs (set of str): directories known to contain the marker file.

    Returns a bool.
    """
    return any(v in marker_dirs for v in session_dir_variants(mouse, date, tp))


def scratch_candidates(analyzed_base, mouse, date, tp):
    """
    analyzed_base (str): scratch base directory for analyzed data.
    mouse (str): mouse ID.
    date (str): session date.
    tp (str): timepoint.

    Returns a list of Path, the tp-level and date-level candidate dirs.
    """
    return [Path(analyzed_base) / mouse / date / tp, Path(analyzed_base) / mouse / date]


def find_local_mmap(analyzed_base, mouse, date, tp):
    """
    analyzed_base (str): scratch base directory for analyzed data.
    mouse (str): mouse ID.
    date (str): session date.
    tp (str): timepoint.

    Returns the Path to a local order_c .mmap file if one exists, else None.
    """
    for candidate in scratch_candidates(analyzed_base, mouse, date, tp):
        if not candidate.exists():
            continue
        for f in candidate.rglob("*.mmap"):
            if "order_c" in f.name.lower():
                return f
    return None


def find_local_zip(analyzed_base, mouse, date, tp):
    """
    analyzed_base (str): scratch base directory for analyzed data.
    mouse (str): mouse ID.
    date (str): session date.
    tp (str): timepoint.

    Returns the Path to a local ROI .zip file if one exists, else None.
    """
    for candidate in scratch_candidates(analyzed_base, mouse, date, tp):
        if not candidate.exists():
            continue
        for f in candidate.rglob("*.zip"):
            return f
    return None
