#!/usr/bin/env python
"""
Unit tests for cnmfe_modeling.resolve_analyzed_path(): the tp-level vs
mouse/date-level fallback logic, and its error message when neither
candidate has everything CNMF-E needs.

Note: cnmfe_modeling.py imports caiman/cv2/roifile at module level, so this
must run inside the Apptainer container, same as the real pipeline:

    apptainer_python tests/test_path_resolution.py

(plain `python tests/test_path_resolution.py` on a laptop will fail on the
caiman import, that's expected -- this isn't testing caiman itself, just the
filesystem logic sitting in front of it)
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cnmfe"))
import cnmfe_modeling
from cnmfe_modeling import resolve_analyzed_path


def touch_required_files(session_dir: Path):
    session_dir.mkdir(parents=True, exist_ok=True)
    (session_dir / "memmap_d1_order_c_frames.mmap").touch()
    (session_dir / "RoiSet.zip").touch()
    (session_dir / "correlation_image.npy").touch()


class TestResolveAnalyzedPath(unittest.TestCase):

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_prefers_tp_level_when_complete(self):
        tp_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        touch_required_files(tp_dir)

        resolved, found = resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertEqual(resolved, tp_dir)
        self.assertEqual(set(found.keys()), {"mmap", "roi", "correlation"})

    def test_falls_back_to_mouse_date_level(self):
        md_dir = self.tmp / "VK_20250101_a" / "2025-01-01"
        touch_required_files(md_dir)

        resolved, found = resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertEqual(resolved, md_dir)

    def test_prefers_tp_level_even_if_mouse_date_also_complete(self):
        tp_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        md_dir = self.tmp / "VK_20250101_a" / "2025-01-01"
        touch_required_files(tp_dir)
        touch_required_files(md_dir)

        resolved, _ = resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertEqual(resolved, tp_dir)

    def test_raises_with_both_candidates_named_when_incomplete(self):
        tp_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        tp_dir.mkdir(parents=True)
        (tp_dir / "memmap_d1_order_c_frames.mmap").touch()  # missing roi + correlation

        with self.assertRaises(FileNotFoundError) as ctx:
            resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")

        message = str(ctx.exception)
        self.assertIn(str(tp_dir), message)
        self.assertIn(str(self.tmp / "VK_20250101_a" / "2025-01-01"), message)
        self.assertIn("roi", message)
        self.assertIn("correlation", message)

    def test_raises_when_neither_path_exists_at_all(self):
        with self.assertRaises(FileNotFoundError):
            resolve_analyzed_path(str(self.tmp), "VK_nonexistent", "2025-01-01", "tp1")


class TestAutoSyncRoiZip(unittest.TestCase):
    """resolve_analyzed_path() should pull a Drive-only ROI zip down
    automatically when it's the *only* thing missing locally, per the
    "run sync" design discussion -- mmap and correlation image still have
    to already be local, only the zip gets this treatment."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_syncs_zip_when_its_the_only_thing_missing(self):
        tp_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        tp_dir.mkdir(parents=True)
        (tp_dir / "memmap_d1_order_c_frames.mmap").touch()
        (tp_dir / "correlation_image.npy").touch()
        # deliberately no .zip -- that's the one thing this candidate lacks

        def fake_sync(remote_dir, local_dir):
            # Simulate what a real `rclone copy --include '*.zip'` would do
            (local_dir / "RoiSet.zip").touch()

        with mock.patch.object(cnmfe_modeling, "find_roi_zip_on_drive", return_value="gdrive:fake/remote/dir") as mock_find, \
             mock.patch.object(cnmfe_modeling, "sync_roi_zip_from_drive", side_effect=fake_sync) as mock_sync:
            resolved, found = resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")

        mock_find.assert_called_once_with("VK_20250101_a", "2025-01-01", "tp1")
        mock_sync.assert_called_once()
        self.assertEqual(resolved, tp_dir)
        self.assertEqual(set(found.keys()), {"mmap", "roi", "correlation"})

    def test_does_not_attempt_sync_when_other_files_also_missing(self):
        # mmap AND roi both missing -- pulling the zip alone wouldn't make
        # this candidate usable anyway (the mmap can never come from Drive),
        # so it shouldn't even try.
        tp_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        tp_dir.mkdir(parents=True)
        (tp_dir / "correlation_image.npy").touch()

        with mock.patch.object(cnmfe_modeling, "find_roi_zip_on_drive") as mock_find:
            with self.assertRaises(FileNotFoundError):
                resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")

        mock_find.assert_not_called()

    def test_raises_cleanly_when_zip_not_on_drive_either(self):
        tp_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        tp_dir.mkdir(parents=True)
        (tp_dir / "memmap_d1_order_c_frames.mmap").touch()
        (tp_dir / "correlation_image.npy").touch()

        with mock.patch.object(cnmfe_modeling, "find_roi_zip_on_drive", return_value=None), \
             mock.patch.object(cnmfe_modeling, "sync_roi_zip_from_drive") as mock_sync:
            with self.assertRaises(FileNotFoundError):
                resolve_analyzed_path(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")

        mock_sync.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
