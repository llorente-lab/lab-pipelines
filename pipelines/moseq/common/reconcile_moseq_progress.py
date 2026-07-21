"""Project-level PCA/modeling progress for a Moseq project."""

from __future__ import annotations

import os
from pathlib import Path

from moseq2_app.gui.progress import generate_initial_progressfile


def get_progress(project_root: str) -> dict:
    """Refresh and return Moseq's progress.yaml for a project."""
    root = Path(project_root).resolve()
    progress_file = str(root / "progress.yaml")

    prev_cwd = os.getcwd()
    try:
        os.chdir(root)
        return generate_initial_progressfile(filename=progress_file)
    finally:
        os.chdir(prev_cwd)


def pca_is_done(project_root: str, progress: dict | None = None) -> bool:
    if progress is None:
        progress = get_progress(project_root)
    return bool(progress.get("scores_path"))


def modeling_is_done(project_root: str, progress: dict | None = None) -> bool:
    """True once at least one model exists in base_model_path (kappa-scan or single fit).

    Distinct from best_model_is_selected(): models can exist without a winner being chosen."""
    if progress is None:
        progress = get_progress(project_root)
    base_model_path = progress.get("base_model_path")
    if not base_model_path:
        return False
    model_dir = Path(base_model_path)
    return model_dir.is_dir() and any(model_dir.glob("*.p"))


def best_model_is_selected(project_root: str, progress: dict | None = None) -> bool:
    """True once model_session_path is populated in progress.yaml."""
    if progress is None:
        progress = get_progress(project_root)
    return bool(progress.get("model_session_path"))
