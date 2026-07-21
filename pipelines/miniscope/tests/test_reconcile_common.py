#!/usr/bin/env python
"""
Unit tests for reconcile_common.py logic. No Sherlock, no Apptainer, no real
rclone/Drive access needed: rclone calls are monkeypatched with canned
output, so this can be run anywhere Python 3.9+ is available, including
directly on a laptop.

Usage:
    python test_reconcile_common.py
    python -m unittest test_reconcile_common -v
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
import reconcile_common as rc


class TestGdrivePath(unittest.TestCase):

    def test_default_prefix(self):
        with mock.patch.object(rc, "MINISCOPE_DRIVE_PREFIX", "Miniscope"):
            self.assertEqual(rc.gdrive_path("AnalyzedData"), "gdrive:Miniscope/AnalyzedData")

    def test_empty_prefix_when_root_folder_id_is_miniscope_itself(self):
        with mock.patch.object(rc, "MINISCOPE_DRIVE_PREFIX", ""):
            self.assertEqual(rc.gdrive_path("AnalyzedData"), "gdrive:AnalyzedData")

    def test_multiple_parts_joined_in_order(self):
        with mock.patch.object(rc, "MINISCOPE_DRIVE_PREFIX", "Miniscope"):
            self.assertEqual(
                rc.gdrive_path("RawData", "VK_20250101_a", "2025-01-01"),
                "gdrive:Miniscope/RawData/VK_20250101_a/2025-01-01",
            )


class TestDiscoverRawSessions(unittest.TestCase):
    """discover_raw_sessions() must only accept real VK_-prefixed mice, three
    levels deep -- this is the exact bug (CaImAn/.git and tests/ pollution)
    hit earlier in the pipeline's development."""

    def test_filters_non_vk_prefixed_dirs(self):
        fake_dirs = [
            "VK_20250101_a/2025-01-01/tp1",
            "CaImAn/.git/refs",
            "tests/some/thing",
            "VK_20250102_b/2025-01-02/tp2-2dpi",
        ]
        with mock.patch.object(rc, "rclone_list_dirs", return_value=fake_dirs):
            sessions = rc.discover_raw_sessions()
        self.assertEqual(
            sorted(sessions),
            [("VK_20250101_a", "2025-01-01", "tp1"), ("VK_20250102_b", "2025-01-02", "tp2-2dpi")],
        )

    def test_ignores_dirs_not_exactly_three_levels_deep(self):
        fake_dirs = ["VK_20250101_a", "VK_20250101_a/2025-01-01", "VK_20250101_a/2025-01-01/tp1/extra"]
        with mock.patch.object(rc, "rclone_list_dirs", return_value=fake_dirs):
            sessions = rc.discover_raw_sessions()
        self.assertEqual(sessions, [])

    def test_empty_when_rclone_returns_nothing(self):
        with mock.patch.object(rc, "rclone_list_dirs", return_value=[]):
            self.assertEqual(rc.discover_raw_sessions(), [])


class TestExcludedMice(unittest.TestCase):

    def test_hardcoded_and_drive_lists_are_combined(self):
        with mock.patch.object(rc, "get_excluded_mice_from_drive", return_value={"VK_99999999_z"}):
            excluded = rc.all_excluded_mice()
        self.assertIn("VK_20250408_a", excluded)  # hardcoded
        self.assertIn("VK_99999999_z", excluded)  # drive-discovered


class TestIterEligibleSessions(unittest.TestCase):

    def test_excluded_mice_are_skipped(self):
        fake_sessions = [
            ("VK_20250408_a", "2025-04-08", "tp1"),  # in EXCLUDE_MICE
            ("VK_20990101_z", "2025-01-01", "tp1"),  # not excluded
        ]
        with mock.patch.object(rc, "discover_raw_sessions", return_value=fake_sessions), \
             mock.patch.object(rc, "all_excluded_mice", return_value=rc.EXCLUDE_MICE):
            result = list(rc.iter_eligible_sessions())
        self.assertEqual(result, [("VK_20990101_z", "2025-01-01", "tp1")])


class TestMarkerDirs(unittest.TestCase):

    def test_collect_marker_dirs_matches_correlation_images(self):
        fake_files = [
            "VK_20250101_a/2025-01-01/tp1/correlation_image.npy",
            "VK_20250101_a/2025-01-01/tp1/some_other_file.txt",
            "VK_20250102_b/2025-01-02/correlation_image_VK_20250102_b_tp1.npy",
        ]
        with mock.patch.object(rc, "rclone_list_files", return_value=fake_files):
            dirs = rc.collect_marker_dirs(["gdrive:Miniscope/AnalyzedData"], rc.is_correlation_image)
        self.assertEqual(
            dirs,
            {"VK_20250101_a/2025-01-01/tp1", "VK_20250102_b/2025-01-02"},
        )

    def test_marker_found_checks_both_tp_and_mouse_date_depth(self):
        marker_dirs = {"VK_20250101_a/2025-01-01"}  # only the mouse/date-level variant
        self.assertTrue(rc.marker_found("VK_20250101_a", "2025-01-01", "tp1", marker_dirs))
        self.assertFalse(rc.marker_found("VK_20250101_a", "2025-01-02", "tp1", marker_dirs))


class TestIsCorrelationImage(unittest.TestCase):
    """Archival sessions processed by an older script (before this rewrite)
    sometimes only synced the PNG visualization, never the bare .npy the
    current pipeline always saves -- both must count as done, or
    reconciliation wrongly re-queues an already-finished session for MC."""

    def test_matches_bare_npy(self):
        self.assertTrue(rc.is_correlation_image("correlation_image.npy"))

    def test_matches_suffixed_npy(self):
        self.assertTrue(rc.is_correlation_image("correlation_image_VK_20250101_a_tp1.npy"))

    def test_matches_png_variant(self):
        self.assertTrue(rc.is_correlation_image("correlation_image_VK_20250701_d_tp2-bsl2.png"))

    def test_rejects_unrelated_file(self):
        self.assertFalse(rc.is_correlation_image("some_other_file.txt"))
        self.assertFalse(rc.is_correlation_image("background_spatial.npy"))


class TestIsCnmfeModel(unittest.TestCase):
    """The current pipeline always saves both .joblib and .hdf5, but some
    archival sessions only have one or the other (or an even older .p
    pickle) -- any of these is solid evidence CNMF-E actually ran."""

    def test_matches_joblib(self):
        self.assertTrue(rc.is_cnmfe_model("cnmfe_model_seeded_VK_20250101_a_2025-01-01.joblib"))

    def test_matches_hdf5(self):
        self.assertTrue(rc.is_cnmfe_model("cnmfe_results_VK_20250101_a_2025-01-01.hdf5"))

    def test_matches_pickle(self):
        self.assertTrue(rc.is_cnmfe_model("cnmfe_model_VK_20250101_a_2025-01-01.p"))

    def test_rejects_unrelated_file(self):
        self.assertFalse(rc.is_cnmfe_model("cnmfe_traces_VK_20250101_a_2025-01-01.csv"))
        self.assertFalse(rc.is_cnmfe_model("cnmfe_contours_VK_20250101_a_2025-01-01.png"))


class TestScratchLookups(unittest.TestCase):
    """find_local_mmap / find_local_zip touch the real filesystem (that's the
    point -- scratch state can't be mocked away), so these use a temp dir."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_finds_mmap_at_tp_level(self):
        session_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        session_dir.mkdir(parents=True)
        (session_dir / "memmap_d1_order_c_frames.mmap").touch()

        result = rc.find_local_mmap(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertIsNotNone(result)
        self.assertTrue(result.name.endswith(".mmap"))

    def test_falls_back_to_mouse_date_level(self):
        session_dir = self.tmp / "VK_20250101_a" / "2025-01-01"
        session_dir.mkdir(parents=True)
        (session_dir / "memmap_d1_order_c_frames.mmap").touch()

        result = rc.find_local_mmap(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertIsNotNone(result)

    def test_ignores_mmap_without_order_c(self):
        session_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        session_dir.mkdir(parents=True)
        (session_dir / "some_other_file.mmap").touch()

        result = rc.find_local_mmap(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertIsNone(result)

    def test_missing_session_returns_none(self):
        result = rc.find_local_mmap(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertIsNone(result)

    def test_finds_zip(self):
        session_dir = self.tmp / "VK_20250101_a" / "2025-01-01" / "tp1"
        session_dir.mkdir(parents=True)
        (session_dir / "RoiSet.zip").touch()

        result = rc.find_local_zip(str(self.tmp), "VK_20250101_a", "2025-01-01", "tp1")
        self.assertIsNotNone(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
