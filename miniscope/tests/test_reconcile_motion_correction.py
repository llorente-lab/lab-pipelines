#!/usr/bin/env python
"""
Unit tests for reconcile_motion_correction.py's find_sessions_needing_mc(),
specifically the two independent "MC is done" signals: a correlation-image
marker, or a CNMF-E model marker. Pure stdlib + mocked rclone, same as
test_reconcile_common.py -- no Sherlock/Drive access needed.

Regression test for a real bug: VK_20250724_a/2025-09-10 has a genuine
.joblib (CNMF-E ran, which structurally requires MC to have already
succeeded) but no recognizable correlation_image file anywhere in its Drive
folder -- an older/archival processing run that never synced one. Before
this fix, reconciliation only trusted the correlation-image marker and
wrongly queued this already-finished session for motion correction.

Usage:
    python test_reconcile_motion_correction.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "motion_correction"))
import reconcile_common as rc
from reconcile_motion_correction import find_sessions_needing_mc


class TestFindSessionsNeedingMC(unittest.TestCase):

    def test_session_with_only_correlation_image_is_done(self):
        fake_files = ["VK_20250101_a/2025-01-01/tp1/correlation_image.npy"]
        with mock.patch.object(rc, "discover_raw_sessions", return_value=[("VK_20250101_a", "2025-01-01", "tp1")]), \
             mock.patch.object(rc, "all_excluded_mice", return_value=set()), \
             mock.patch.object(rc, "rclone_list_files", return_value=fake_files):
            needs_mc = find_sessions_needing_mc()
        self.assertEqual(needs_mc, [])

    def test_session_with_only_cnmfe_model_is_done(self):
        # Regression case: real VK_20250724_a/2025-09-10 -- a .joblib exists
        # (proving MC succeeded, since CNMF-E can't run without it) but no
        # correlation_image file of any kind synced for this archival run.
        fake_files = ["VK_20250724_a/2025-09-10/cnmfe_model_seeded_VK_20250724_a_2025-09-10.joblib"]
        with mock.patch.object(rc, "discover_raw_sessions", return_value=[("VK_20250724_a", "2025-09-10", "tp1")]), \
             mock.patch.object(rc, "all_excluded_mice", return_value=set()), \
             mock.patch.object(rc, "rclone_list_files", return_value=fake_files):
            needs_mc = find_sessions_needing_mc()
        self.assertEqual(needs_mc, [])

    def test_session_with_neither_marker_needs_mc(self):
        with mock.patch.object(rc, "discover_raw_sessions", return_value=[("VK_20250101_a", "2025-01-01", "tp1")]), \
             mock.patch.object(rc, "all_excluded_mice", return_value=set()), \
             mock.patch.object(rc, "rclone_list_files", return_value=[]):
            needs_mc = find_sessions_needing_mc()
        self.assertEqual(needs_mc, [("VK_20250101_a", "2025-01-01", "tp1")])


if __name__ == "__main__":
    unittest.main(verbosity=2)
