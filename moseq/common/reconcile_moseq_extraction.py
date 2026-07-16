"""
Per-session extraction status for a Moseq project. Pure stdlib, no
moseq2_extract import, deliberately -- moseq2_extract pulls in cv2/h5py/scipy
at module load, which would force this simple check to require the
Apptainer container just to read one boolean out of a yaml file. Since
check_completion_status() really is only this:

    def check_completion_status(status_filename):
        if exists(status_filename):
            return read_yaml(status_filename)["complete"]
        return False

(confirmed by reading moseq2-extract's actual source, no side effects, no
GUI/widget coupling), it's cheap and safe to duplicate here rather than pull
in the whole extraction package's import chain. If moseq2-extract's status
file format ever changes, this needs to be updated to match -- it is a
deliberate, small duplication, not an attempt to reinvent extraction status
tracking.

Testable without Sherlock/Apptainer, same as reconcile_common.py.
"""

from __future__ import annotations

from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - yaml is a moseq2 dependency too,
    # but keep this file importable in a bare environment for testing.
    yaml = None


def is_session_dir(path: Path) -> bool:
    """
    A Moseq session directory: one level under the project root, containing
    either metadata.json (raw session marker) or a proc/ subdirectory
    (already-extracted marker). Kept permissive on purpose -- projects may
    have inconsistent raw-data layouts (unlike Miniscope, there's no single
    canonical RawData convention here), so this errs toward "is this
    plausibly a session" rather than requiring an exact file set.
    """
    if not path.is_dir():
        return False
    return (path / "metadata.json").exists() or (path / "proc").is_dir()


def find_session_dirs(project_root: str) -> list[Path]:
    """Immediate subdirectories of project_root that look like sessions."""
    root = Path(project_root)
    if not root.is_dir():
        return []
    return sorted(p for p in root.iterdir() if is_session_dir(p))


def check_completion_status(status_filename: Path) -> bool:
    """
    Local reimplementation of moseq2_extract.helpers.data.check_completion_status.
    See module docstring for why this is duplicated rather than imported.
    """
    if not status_filename.exists():
        return False
    if yaml is None:
        raise RuntimeError("pyyaml is required to read extraction status files")
    with open(status_filename) as f:
        data = yaml.safe_load(f) or {}
    return bool(data.get("complete", False))


def get_extraction_status(project_root: str) -> dict[str, bool]:
    """
    {session_name: True/False} for every session directory found under
    project_root, based on proc/results_00.yaml's complete field.
    """
    return {
        session_dir.name: check_completion_status(session_dir / "proc" / "results_00.yaml")
        for session_dir in find_session_dirs(project_root)
    }


def sessions_needing_extraction(project_root: str) -> list[str]:
    """Session names where extraction has not completed yet."""
    status = get_extraction_status(project_root)
    return [name for name, done in status.items() if not done]
