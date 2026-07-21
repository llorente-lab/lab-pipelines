"""Per-session extraction status for a Moseq project."""

from __future__ import annotations

from pathlib import Path

try:
    import yaml
except ImportError: 
    yaml = None


def is_session_dir(path: Path) -> bool:
    """Return True if path looks like a Moseq session directory."""
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
    """Local reimplementation of moseq2_extract.helpers.data.check_completion_status."""
    if not status_filename.exists():
        return False
    if yaml is None:
        raise RuntimeError("pyyaml is required to read extraction status files")
    with open(status_filename) as f:
        data = yaml.safe_load(f) or {}
    return bool(data.get("complete", False))


def get_extraction_status(project_root: str) -> dict[str, bool]:
    return {
        session_dir.name: check_completion_status(session_dir / "proc" / "results_00.yaml")
        for session_dir in find_session_dirs(project_root)
    }


def sessions_needing_extraction(project_root: str) -> list[str]:
    """Session names where extraction has not completed yet."""
    status = get_extraction_status(project_root)
    return [name for name, done in status.items() if not done]
