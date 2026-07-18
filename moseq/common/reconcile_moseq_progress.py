"""
Project-level (PCA/modeling) progress for a Moseq project. Thin wrapper
around moseq2-app's own generate_intital_progressfile()/find_progress(),
confirmed safe to call directly outside any GUI/notebook context (no
ipywidgets coupling, pure stdlib + ruamel.yaml + toolz +
moseq2_extract.helpers.data.check_completion_status internally).

Requires the Apptainer container (moseq2_app pulls in bokeh/panel/etc. at
import time), same as cnmfe_modeling.py on the Miniscope side -- not
unit-testable outside Sherlock. See moseq/tests/ (once it exists) for the
apptainer_python-gated test, mirroring test_path_resolution.py's pattern.

Two things to know about find_progress(), confirmed by reading its source:

1. It has a real side effect: if it finds a PCA scores file, it patches
   pca_path into moseq2-index.yaml on disk. This is intentional and fine --
   it's recording something true, not fabricating state -- just don't treat
   get_progress() as a pure read.

2. There's a latent relative-path bug: when pca_dirname is still '' (PCA
   hasn't run yet), it does exists(join('', 'changepoints.h5')), i.e.
   exists('changepoints.h5') relative to the CURRENT working directory, not
   project_root. If this function were called from an unrelated cwd that
   happened to contain a changepoints.h5, that would be a false positive.
   get_progress() below neutralizes this by chdir-ing into project_root
   before calling, so the fallback resolves inside the correct project
   (degrading to the intended "not found" behavior) instead of wherever the
   caller's process happened to start.
"""

from __future__ import annotations

import os
from pathlib import Path

from moseq2_app.gui.progress import generate_initial_progressfile


def get_progress(project_root: str) -> dict:
    """
    Refresh and return Moseq's own progress.yaml for a project. Always
    resolves project_root to an absolute path and passes an absolute
    progress-file path (generate_intital_progressfile's default is a
    relative "progress.yaml", which would otherwise resolve against
    whatever this function's caller's cwd happens to be).
    """
    root = Path(project_root).resolve()
    progress_file = str(root / "progress.yaml")

    prev_cwd = os.getcwd()
    try:
        os.chdir(root)
        return generate_initial_progressfile(filename=progress_file)
    finally:
        os.chdir(prev_cwd)


def pca_is_done(project_root: str) -> bool:
    progress = get_progress(project_root)
    return bool(progress.get("scores_path"))


def modeling_is_done(project_root: str) -> bool:
    """
    True once at least one model has been trained (kappa-scan or a single
    fit), i.e. base_model_path is populated and non-empty. This is
    deliberately NOT the same question as "has a best model been selected"
    -- see best_model_is_selected() below. progress.yaml has no plain
    "model_path" field (an earlier version of this file incorrectly assumed
    one); the real fields are base_model_path (folder of all trained
    models) and model_session_path (the one model picked for analysis).
    """
    progress = get_progress(project_root)
    base_model_path = progress.get("base_model_path")
    if not base_model_path:
        return False
    model_dir = Path(base_model_path)
    return model_dir.is_dir() and any(model_dir.glob("*.p"))


def best_model_is_selected(project_root: str) -> bool:
    """
    True once a specific model has been chosen for downstream analysis
    (progress.yaml's model_session_path), e.g. after "Get Best Model Fit"
    has run. A project can have modeling_is_done() == True (models were
    trained) while this is still False (nobody picked one yet).
    """
    progress = get_progress(project_root)
    return bool(progress.get("model_session_path"))
