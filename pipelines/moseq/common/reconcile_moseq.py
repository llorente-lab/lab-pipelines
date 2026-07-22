"""
Completion status for a Moseq project: per-session extraction status, plus
project-level PCA/modeling progress. Combined into one file since both are
only ever needed together, from `run moseq check-progress <name>`.

The moseq2_app import (needed for progress.yaml) is done lazily inside
get_progress(), so this module can still be imported and its extraction
helpers tested on a bare host, without the container.
"""

import os
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


# --- per-session extraction status ---


def is_session_dir(path):
    """
    Whether path looks like a Moseq session directory.

    path (Path): candidate directory.

    Returns a bool.
    """
    if not path.is_dir():
        return False
    return (path / "metadata.json").exists() or (path / "proc").is_dir()


def find_session_dirs(project_root):
    """
    Immediate subdirectories of project_root that look like sessions.

    project_root (str): project's root directory.

    Returns a list of Path objects.
    """
    root = Path(project_root)
    if not root.is_dir():
        return []
    return sorted(p for p in root.iterdir() if is_session_dir(p))


def check_completion_status(status_filename):
    """
    Local reimplementation of
    moseq2_extract.helpers.data.check_completion_status.

    status_filename (Path): path to a session's results_00.yaml.

    Returns a bool.
    """
    if not status_filename.exists():
        return False
    if yaml is None:
        raise RuntimeError("pyyaml is required to read extraction status files")
    with open(status_filename) as f:
        data = yaml.safe_load(f) or {}
    return bool(data.get("complete", False))


def get_extraction_status(project_root):
    """
    project_root (str): project's root directory.

    Returns a dict mapping session name (str) to whether extraction has
    completed (bool).
    """
    return {
        session_dir.name: check_completion_status(session_dir / "proc" / "results_00.yaml")
        for session_dir in find_session_dirs(project_root)
    }


def sessions_needing_extraction(project_root):
    """
    Session names where extraction has not completed yet.

    project_root (str): project's root directory.

    Returns a list of session names (str).
    """
    status = get_extraction_status(project_root)
    return [name for name, done in status.items() if not done]


# --- project-level PCA/modeling progress (needs the container) ---


def get_progress(project_root):
    """
    Refresh and return Moseq's progress.yaml for a project.

    project_root (str): project's root directory.

    Returns a dict, the parsed progress.yaml contents.
    """
    from moseq2_app.gui.progress import generate_initial_progressfile

    root = Path(project_root).resolve()
    progress_file = str(root / "progress.yaml")

    prev_cwd = os.getcwd()
    try:
        os.chdir(root)
        return generate_initial_progressfile(filename=progress_file)
    finally:
        os.chdir(prev_cwd)


def pca_is_done(progress):
    """progress (dict): a project's progress.yaml contents. Returns a bool."""
    return bool(progress.get("scores_path"))


def modeling_is_done(progress):
    """
    True once at least one model exists in base_model_path (kappa-scan or
    single fit). Distinct from best_model_is_selected(): models can exist
    without a winner being chosen.

    progress (dict): a project's progress.yaml contents.

    Returns a bool.
    """
    base_model_path = progress.get("base_model_path")
    if not base_model_path:
        return False
    model_dir = Path(base_model_path)
    return model_dir.is_dir() and any(model_dir.glob("*.p"))


def best_model_is_selected(progress):
    """
    True once model_session_path is populated in progress.yaml.

    progress (dict): a project's progress.yaml contents.

    Returns a bool.
    """
    return bool(progress.get("model_session_path"))


# --- the one call check-progress actually needs ---


def get_completion_info(project_root):
    """
    Everything `run moseq check-progress` reports, in one call. Needs the
    container (get_progress does), so call this via apptainer_python.

    project_root (str): project's root directory.

    Returns a dict:
      sessions_needing_extraction (list of str)
      pca_done (bool)
      modeling_done (bool)
      best_model_selected (bool)
    """
    progress = get_progress(project_root)
    return {
        "sessions_needing_extraction": sessions_needing_extraction(project_root),
        "pca_done": pca_is_done(progress),
        "modeling_done": modeling_is_done(progress),
        "best_model_selected": best_model_is_selected(progress),
    }
