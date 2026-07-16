#!/usr/bin/env python
"""
Unit tests for reconcile_moseq_extraction.py. Pure stdlib + pyyaml, no
Sherlock/Apptainer/moseq2 packages needed -- same philosophy as
miniscope/tests/test_reconcile_common.py.

Usage:
    python test_reconcile_moseq_extraction.py
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from reconcile_moseq_extraction import (
    check_completion_status,
    find_session_dirs,
    get_extraction_status,
    is_session_dir,
    sessions_needing_extraction,
)


def write_status(session_dir: Path, complete: bool):
    proc = session_dir / "proc"
    proc.mkdir(parents=True, exist_ok=True)
    (proc / "results_00.yaml").write_text(f"complete: {str(complete).lower()}\n")


class TestIsSessionDir(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_recognizes_metadata_json(self):
        d = self.tmp / "session_a"
        d.mkdir()
        (d / "metadata.json").write_text("{}")
        self.assertTrue(is_session_dir(d))

    def test_recognizes_proc_dir(self):
        d = self.tmp / "session_b"
        d.mkdir()
        (d / "proc").mkdir()
        self.assertTrue(is_session_dir(d))

    def test_rejects_unrelated_dir(self):
        d = self.tmp / "not_a_session"
        d.mkdir()
        (d / "readme.txt").write_text("hi")
        self.assertFalse(is_session_dir(d))

    def test_rejects_files(self):
        f = self.tmp / "some_file.txt"
        f.write_text("hi")
        self.assertFalse(is_session_dir(f))


class TestCheckCompletionStatus(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_true_when_complete(self):
        session = self.tmp / "session_a"
        write_status(session, True)
        self.assertTrue(check_completion_status(session / "proc" / "results_00.yaml"))

    def test_false_when_incomplete(self):
        session = self.tmp / "session_a"
        write_status(session, False)
        self.assertFalse(check_completion_status(session / "proc" / "results_00.yaml"))

    def test_false_when_missing(self):
        session = self.tmp / "session_a"
        session.mkdir()
        self.assertFalse(check_completion_status(session / "proc" / "results_00.yaml"))


class TestProjectLevelHelpers(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_find_session_dirs_ignores_non_sessions(self):
        (self.tmp / "session_a" / "proc").mkdir(parents=True)
        (self.tmp / "session_b").mkdir()
        (self.tmp / "session_b" / "metadata.json").write_text("{}")
        (self.tmp / "plots").mkdir()  # not a session
        (self.tmp / "config.yaml").write_text("")  # not a dir

        found = {p.name for p in find_session_dirs(str(self.tmp))}
        self.assertEqual(found, {"session_a", "session_b"})

    def test_get_extraction_status_mixed(self):
        write_status(self.tmp / "session_a", True)
        write_status(self.tmp / "session_b", False)
        (self.tmp / "session_c").mkdir()
        (self.tmp / "session_c" / "metadata.json").write_text("{}")  # never extracted

        status = get_extraction_status(str(self.tmp))
        self.assertEqual(status, {"session_a": True, "session_b": False, "session_c": False})

    def test_sessions_needing_extraction(self):
        write_status(self.tmp / "session_a", True)
        write_status(self.tmp / "session_b", False)

        needing = sessions_needing_extraction(str(self.tmp))
        self.assertEqual(needing, ["session_b"])

    def test_empty_project_returns_empty(self):
        self.assertEqual(find_session_dirs(str(self.tmp)), [])
        self.assertEqual(get_extraction_status(str(self.tmp)), {})
        self.assertEqual(sessions_needing_extraction(str(self.tmp)), [])

    def test_nonexistent_project_returns_empty(self):
        self.assertEqual(find_session_dirs(str(self.tmp / "does_not_exist")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
