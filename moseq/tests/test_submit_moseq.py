#!/usr/bin/env python
"""
Unit tests for submit_moseq.py's sbatch-wrapping and dependency-chaining
logic. Mocks subprocess.run entirely -- no real sbatch, no Sherlock, no
container needed (submit_moseq.py only imports subprocess/re/pathlib and
reconcile_moseq_extraction, all pure stdlib).

Usage:
    python test_submit_moseq.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
import submit_moseq


def fake_sbatch_result(job_id: str) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        args=["sbatch"], returncode=0, stdout=f"Submitted batch job {job_id}\n", stderr=""
    )


class TestSbatchJobIdParsing(unittest.TestCase):
    def test_parses_job_id_from_normal_output(self):
        with mock.patch.object(subprocess, "run", return_value=fake_sbatch_result("12345")):
            job_id = submit_moseq._sbatch(Path("fake.sbatch"), "arg1")
        self.assertEqual(job_id, "12345")

    def test_raises_on_unparseable_output(self):
        bad_result = subprocess.CompletedProcess(
            args=["sbatch"], returncode=0, stdout="something unexpected\n", stderr=""
        )
        with mock.patch.object(subprocess, "run", return_value=bad_result):
            with self.assertRaises(RuntimeError):
                submit_moseq._sbatch(Path("fake.sbatch"), "arg1")

    def test_dependency_flags_come_before_script_path(self):
        captured_cmd = []

        def fake_run(cmd, **kwargs):
            captured_cmd.extend(cmd)
            return fake_sbatch_result("999")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            submit_moseq._sbatch(
                Path("fake.sbatch"), "positional_arg",
                sbatch_flags=["--dependency=afterok:1:2"],
            )

        # sbatch requires flags before the script path, positional args after
        script_index = captured_cmd.index("fake.sbatch")
        flag_index = captured_cmd.index("--dependency=afterok:1:2")
        arg_index = captured_cmd.index("positional_arg")
        self.assertLess(flag_index, script_index)
        self.assertGreater(arg_index, script_index)


class TestDependencyFlags(unittest.TestCase):
    def test_none_when_no_dependencies(self):
        self.assertIsNone(submit_moseq._dependency_flags(None))
        self.assertIsNone(submit_moseq._dependency_flags([]))

    def test_single_dependency(self):
        self.assertEqual(
            submit_moseq._dependency_flags(["123"]), ["--dependency=afterok:123"]
        )

    def test_multiple_dependencies_joined_with_colons(self):
        self.assertEqual(
            submit_moseq._dependency_flags(["123", "456", "789"]),
            ["--dependency=afterok:123:456:789"],
        )


class TestSubmitExtraction(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_submits_one_job_per_incomplete_session(self):
        # session_a: already extracted (should be skipped)
        proc_a = self.tmp / "session_a" / "proc"
        proc_a.mkdir(parents=True)
        (proc_a / "results_00.yaml").write_text("complete: true\n")

        # session_b: not yet extracted (should get a job)
        session_b = self.tmp / "session_b"
        session_b.mkdir()
        (session_b / "metadata.json").write_text("{}")

        submitted_args = []

        def fake_run(cmd, **kwargs):
            submitted_args.append(cmd)
            return fake_sbatch_result(str(100 + len(submitted_args)))

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            job_ids = submit_moseq.submit_extraction(str(self.tmp))

        self.assertEqual(job_ids, ["101"])
        self.assertEqual(len(submitted_args), 1)
        self.assertIn(str(session_b), submitted_args[0])

    def test_no_jobs_when_everything_already_extracted(self):
        proc_a = self.tmp / "session_a" / "proc"
        proc_a.mkdir(parents=True)
        (proc_a / "results_00.yaml").write_text("complete: true\n")

        with mock.patch.object(subprocess, "run") as mock_run:
            job_ids = submit_moseq.submit_extraction(str(self.tmp))

        self.assertEqual(job_ids, [])
        mock_run.assert_not_called()


class TestSubmitMasterChaining(unittest.TestCase):
    """
    submit_master() should chain every stage via --dependency=afterok on
    the previous stage's job ID(s), so e.g. PCA fit can never race ahead of
    aggregation. Mocks each submit_* function directly rather than
    subprocess, to isolate the chaining logic itself from sbatch-call
    details already covered above.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_chains_stages_in_order_with_correct_dependencies(self):
        with mock.patch.object(submit_moseq, "submit_extraction", return_value=["1", "2"]) as m_extract, \
             mock.patch.object(submit_moseq, "submit_aggregate", return_value="3") as m_agg, \
             mock.patch.object(submit_moseq, "submit_pca_fit", return_value="4") as m_fit, \
             mock.patch.object(submit_moseq, "submit_pca_apply", return_value="5") as m_apply, \
             mock.patch.object(submit_moseq, "submit_compute_changepoints", return_value="6") as m_cp:
            result = submit_moseq.submit_master(str(self.tmp))

        m_agg.assert_called_once_with(str(self.tmp), depends_on=["1", "2"])
        m_fit.assert_called_once_with(str(self.tmp), None, depends_on=["3"])
        m_apply.assert_called_once_with(str(self.tmp), None, depends_on=["4"])
        m_cp.assert_called_once_with(str(self.tmp), None, depends_on=["5"])
        self.assertEqual(
            result,
            {
                "extraction": ["1", "2"],
                "aggregate": "3",
                "pca_fit": "4",
                "pca_apply": "5",
                "compute_changepoints": "6",
            },
        )

    def test_aggregate_gets_no_dependency_when_extraction_submits_nothing(self):
        with mock.patch.object(submit_moseq, "submit_extraction", return_value=[]), \
             mock.patch.object(submit_moseq, "submit_aggregate", return_value="1") as m_agg, \
             mock.patch.object(submit_moseq, "submit_pca_fit", return_value="2"), \
             mock.patch.object(submit_moseq, "submit_pca_apply", return_value="3"), \
             mock.patch.object(submit_moseq, "submit_compute_changepoints", return_value="4"):
            submit_moseq.submit_master(str(self.tmp))

        m_agg.assert_called_once_with(str(self.tmp), depends_on=None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
