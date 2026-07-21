#!/usr/bin/env python
"""
Multisession spatial component registration for the miniscope pipeline.
Uses CaImAn's register_multisession to align spatial footprints across
sessions for one or more mice, keyed by session date.

Finds model files from gdrive:Miniscope/AnalyzedData, downloads them to
scratch, runs registration, and syncs the result back to Drive at
<mouse>/multisession_registration.joblib.

Skips mice that already have a result on Drive unless --force is given.
Warns (but continues) if not all sessions for a mouse have been modeled.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

import h5py
import joblib
import numpy as np
import pickle
import scipy.sparse

from caiman.base.rois import register_multisession
from caiman.source_extraction.cnmf.cnmf import load_CNMF

from reconcile_common import (
    ANALYZED_CANONICAL,
    MOUSE_NAME_PATTERN,
    all_excluded_mice,
    is_cnmfe_model,
    rclone_list_dirs,
    rclone_list_files,
)

MULTISESSION_FILENAME = "multisession_registration.joblib"
MODEL_PRIORITY = [".joblib", ".hdf5", ".p", ".pkl"]

SCRATCH = os.environ.get("SCRATCH", f"/scratch/users/{os.environ.get('USER', 'unknown')}")
TMP_BASE = Path(SCRATCH) / "Miniscope" / "_multisession_tmp"


# ---------------------------------------------------------------------------
# Model loading
# ---------------------------------------------------------------------------

def _load_model(f):
    f = Path(f)
    if not f.exists():
        raise FileNotFoundError(f)
    suffix = f.suffix.lower()
    if suffix == ".hdf5":
        return load_CNMF(str(f))
    elif suffix == ".joblib":
        return joblib.load(str(f))
    elif suffix in (".pkl", ".p"):
        with open(f, "rb") as fh:
            return pickle.load(fh)
    else:
        raise ValueError(f"{f.suffix} is unsupported")


def _get_attr(obj, attr):
    if isinstance(obj, dict):
        if attr in obj.get("estimates", {}):
            return obj["estimates"][attr]
        return obj.get(attr)
    if hasattr(obj, "estimates") and hasattr(obj.estimates, attr):
        return getattr(obj.estimates, attr)
    return getattr(obj, attr, None)


def extract_from_model(model_path: Path):
    model_path = Path(model_path)
    if model_path.suffix.lower() == ".hdf5":
        try:
            model = load_CNMF(str(model_path))
            return _get_attr(model, "C"), _get_attr(model, "A")
        except Exception:
            with h5py.File(model_path, "r") as f:
                C = f["estimates/C"][:] if "estimates/C" in f else None
                if "estimates/A" in f:
                    a = f["estimates/A"]
                    A = scipy.sparse.csc_matrix(
                        (a["data"][:], a["indices"][:], a["indptr"][:]),
                        shape=tuple(a["shape"][:]),
                    )
                else:
                    A = None
            return C, A
    else:
        model = _load_model(model_path)
        return _get_attr(model, "C"), _get_attr(model, "A")


def get_dims_from_model(model_path: Path) -> Optional[tuple]:
    """Try to extract (d1, d2) from the model object or HDF5 metadata."""
    try:
        model = _load_model(model_path)
        dims = _get_attr(model, "dims")
        if dims is not None and len(dims) >= 2:
            return tuple(int(d) for d in dims[:2])
    except Exception:
        pass
    if model_path.suffix.lower() == ".hdf5":
        try:
            with h5py.File(model_path, "r") as f:
                for key in ("dims", "estimates/dims"):
                    if key in f:
                        return tuple(int(d) for d in f[key][:2])
        except Exception:
            pass
    return None


# ---------------------------------------------------------------------------
# Drive / rclone helpers
# ---------------------------------------------------------------------------

def _rclone_copy(src: str, dst: str):
    subprocess.run(["rclone", "copy", src, dst], check=True)


def _drive_file_exists(drive_path: str) -> bool:
    fname = drive_path.split("/")[-1]
    parent = "/".join(drive_path.split("/")[:-1])
    result = subprocess.run(["rclone", "lsf", parent], capture_output=True, text=True)
    return fname in result.stdout


def already_registered(mouse: str) -> bool:
    return _drive_file_exists(f"{ANALYZED_CANONICAL}/{mouse}/{MULTISESSION_FILENAME}")


def discover_mice() -> list[str]:
    dirs = rclone_list_dirs(ANALYZED_CANONICAL, max_depth=1)
    return sorted(d for d in dirs if MOUSE_NAME_PATTERN.match(d.split("/")[0]))


def discover_session_models(mouse: str) -> dict[tuple[str, str], list[str]]:
    """
    Returns {(date, tp): [rel_paths]} for all sessions under
    ANALYZED_CANONICAL/<mouse>/ that have at least one model file.
    tp is "" for old-style sessions without a tp-level directory.
    """
    session_models: dict[tuple[str, str], list[str]] = {}
    for rel in rclone_list_files(f"{ANALYZED_CANONICAL}/{mouse}"):
        parts = rel.split("/")
        fname = parts[-1]
        if not is_cnmfe_model(fname):
            continue
        date = parts[0]
        tp = parts[1] if len(parts) >= 3 else ""
        session_models.setdefault((date, tp), []).append(rel)
    return session_models


def all_session_dirs(mouse: str) -> set[tuple[str, str]]:
    """All (date, tp) directory pairs that exist under this mouse on Drive."""
    sessions = set()
    for d in rclone_list_dirs(f"{ANALYZED_CANONICAL}/{mouse}", max_depth=2):
        parts = d.split("/")
        if len(parts) == 2:
            sessions.add((parts[0], parts[1]))
        elif len(parts) == 1:
            sessions.add((parts[0], ""))
    return sessions


def pick_model_file(candidates: list[str]) -> Optional[str]:
    for ext in MODEL_PRIORITY:
        for f in candidates:
            if f.lower().endswith(ext):
                return f
    return None


def download_file(mouse: str, rel_path: str, tmp_root: Path) -> Path:
    src = f"{ANALYZED_CANONICAL}/{mouse}/{rel_path}"
    dst_dir = tmp_root / mouse / Path(rel_path).parent
    dst_dir.mkdir(parents=True, exist_ok=True)
    _rclone_copy(src, str(dst_dir))
    return dst_dir / Path(rel_path).name


def get_template_and_dims(
    mouse: str, date: str, tp: str, tmp_root: Path
) -> tuple[Optional[np.ndarray], Optional[tuple]]:
    """
    Download correlation_image.npy from Drive (tp-level first, then date-level).
    Returns (image_2d, (d1, d2)) or (None, None).
    """
    candidates = []
    if tp:
        candidates.append(f"{date}/{tp}/correlation_image.npy")
    candidates.append(f"{date}/correlation_image.npy")

    for rel in candidates:
        src = f"{ANALYZED_CANONICAL}/{mouse}/{rel}"
        dst_dir = tmp_root / mouse / "_templates" / rel.replace("/", "_")
        dst_dir.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(["rclone", "copy", src, str(dst_dir)], capture_output=True)
        local = dst_dir / "correlation_image.npy"
        if result.returncode == 0 and local.exists():
            img = np.load(str(local))
            return img, img.shape[:2]
    return None, None


# ---------------------------------------------------------------------------
# Per-mouse registration
# ---------------------------------------------------------------------------

def run_mouse(mouse: str, force: bool, tmp_root: Path) -> bool:
    print(f"\n{'='*60}")
    print(f"mouse: {mouse}")

    if not force and already_registered(mouse):
        print("  already registered — skipping (pass --force to rerun)")
        return True

    session_models = discover_session_models(mouse)
    unmodeled = all_session_dirs(mouse) - set(session_models.keys())
    for date, tp in sorted(unmodeled):
        label = f"{date}/{tp}" if tp else date
        print(f"  WARNING: {label} has no model — proceeding without it")

    if not session_models:
        print("  no sessions with models found — skipping")
        return False

    A_list: list = []
    templates_list: list = []
    session_keys: list[str] = []
    dims: Optional[tuple] = None
    skipped: list[str] = []

    for (date, tp) in sorted(session_models.keys()):
        label = f"{date}/{tp}" if tp else date
        model_rel = pick_model_file(session_models[(date, tp)])
        if model_rel is None:
            skipped.append(label)
            continue

        try:
            local_model = download_file(mouse, model_rel, tmp_root)
        except subprocess.CalledProcessError as e:
            print(f"  WARNING: download failed for {label}: {e}")
            skipped.append(label)
            continue

        try:
            _, A = extract_from_model(local_model)
        except Exception as e:
            print(f"  WARNING: load failed for {label}: {e}")
            skipped.append(label)
            continue

        if A is None:
            print(f"  WARNING: no spatial footprints in {label}")
            skipped.append(label)
            continue

        template, session_dims = get_template_and_dims(mouse, date, tp, tmp_root)

        if dims is None:
            dims = session_dims or get_dims_from_model(local_model)

        if template is None and dims is not None:
            # Fallback: sum of spatial footprints as a rough template
            template = np.array(A.sum(axis=1)).reshape(dims)

        if dims is None or template is None:
            print(f"  WARNING: cannot determine dims/template for {label} — skipping")
            skipped.append(label)
            continue

        A_list.append(A)
        templates_list.append(template)
        session_keys.append(date)
        print(f"  loaded {label}: {A.shape[1]} components")

    if skipped:
        print(f"  skipped {len(skipped)} session(s): {', '.join(skipped)}")

    if len(A_list) < 2:
        print("  fewer than 2 usable sessions — cannot register")
        return False

    print(f"  registering {len(A_list)} sessions...")
    spatial_union, assignments, matchings = register_multisession(
        A=A_list, dims=dims, templates=templates_list
    )

    result = {
        "spatial_union": spatial_union,
        "assignments": assignments,
        "matchings": matchings,
        "session_keys": session_keys,
    }

    out_dir = tmp_root / mouse
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / MULTISESSION_FILENAME
    joblib.dump(result, str(out_file))

    drive_dest = f"{ANALYZED_CANONICAL}/{mouse}"
    _rclone_copy(str(out_file), drive_dest)
    print(f"  → {drive_dest}/{MULTISESSION_FILENAME}")
    return True


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mouse", default=None)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    excluded = all_excluded_mice()

    if args.mouse:
        mice = [args.mouse]
    else:
        mice = [m for m in discover_mice() if m not in excluded]

    print(f"processing {len(mice)} mouse/mice")

    failures = []
    for mouse in mice:
        if mouse in excluded:
            print(f"\n{mouse}: excluded — skipping")
            continue
        try:
            if not run_mouse(mouse, force=args.force, tmp_root=TMP_BASE):
                failures.append(mouse)
        except Exception as e:
            print(f"\n{mouse}: ERROR — {e}")
            failures.append(mouse)

    print(f"\n{'='*60}")
    print(f"done: {len(mice) - len(failures)} succeeded, {len(failures)} failed")
    if failures:
        print(f"failed: {', '.join(failures)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
