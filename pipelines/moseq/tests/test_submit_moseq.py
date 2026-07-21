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


class TestResourceFlags(unittest.TestCase):
    """
    Unit tests for _resource_flags() itself -- no subprocess/mocking needed,
    it's a pure function of (stage, metadata, exclusive, cores, mem_gb, time)
    plus the real pipelines/moseq/resources.yaml registry on disk. See also
    scripts/test_resource_params.sh for the same logic exercised end-to-end
    through the real `run` CLI with sbatch stubbed.
    """

    def test_defaults_use_registry_fallback(self):
        flags = submit_moseq._resource_flags("aggregate", {})
        self.assertTrue(any(f.startswith("--partition=") for f in flags))
        self.assertTrue(any(f.startswith("--cpus-per-task=") for f in flags))
        self.assertTrue(any(f.startswith("--mem=") for f in flags))
        self.assertFalse(any(f == "--exclusive" for f in flags))

    def test_exclusive_drops_formula_derived_cores_and_mem(self):
        flags = submit_moseq._resource_flags("aggregate", {}, exclusive=True)
        self.assertIn("--exclusive", flags)
        self.assertFalse(any(f.startswith("--cpus-per-task=") for f in flags))
        self.assertFalse(any(f.startswith("--mem=") for f in flags))

    def test_explicit_cores_wins_even_combined_with_exclusive(self):
        flags = submit_moseq._resource_flags("aggregate", {}, exclusive=True, cores=8)
        self.assertIn("--exclusive", flags)
        self.assertIn("--cpus-per-task=8", flags)

    def test_explicit_cores_mem_time_override_the_registry(self):
        flags = submit_moseq._resource_flags(
            "aggregate", {}, cores=16, mem_gb=200, time="1-00:00:00"
        )
        self.assertIn("--cpus-per-task=16", flags)
        self.assertIn("--mem=200G", flags)
        self.assertIn("--time=1-00:00:00", flags)

    def test_pca_fit_mem_formula_scales_with_n_sessions(self):
        # pca-fit's mem_gb formula is "n_sessions * 50" -- 4 sessions -> 200GB.
        flags = submit_moseq._resource_flags("pca-fit", {"n_sessions": 4})
        self.assertIn("--mem=200G", flags)

    def test_unknown_stage_returns_no_registry_derived_flags(self):
        flags = submit_moseq._resource_flags("not-a-real-stage", {})
        self.assertFalse(any(f.startswith("--partition=") for f in flags))
        self.assertFalse(any(f.startswith("--cpus-per-task=") for f in flags))


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
    def test_empty_list_when_no_dependencies(self):
        # Returns [] (not None) so it composes cleanly with _log_flags()
        # via list concatenation in _sbatch_flags().
        self.assertEqual(submit_moseq._dependency_flags(None), [])
        self.assertEqual(submit_moseq._dependency_flags([]), [])

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

    def test_submits_one_job_for_project_when_sessions_need_extraction(self):
        # session_a: already extracted (should be skipped by batch-extract)
        proc_a = self.tmp / "session_a" / "proc"
        proc_a.mkdir(parents=True)
        (proc_a / "results_00.yaml").write_text("complete: true\n")

        # session_b: not yet extracted
        session_b = self.tmp / "session_b"
        session_b.mkdir()
        (session_b / "metadata.json").write_text("{}")

        submitted_args = []

        def fake_run(cmd, **kwargs):
            submitted_args.append(cmd)
            return fake_sbatch_result("101")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            job_ids = submit_moseq.submit_extraction(str(self.tmp))

        self.assertEqual(job_ids, ["101"])
        # one array-job submission for the whole project (not one per
        # session), plus the automatic validate_extractions.sbatch chained
        # via --dependency=afterany on that array job.
        self.assertEqual(len(submitted_args), 2)
        self.assertTrue(any(c.endswith("extract_array.sbatch") for c in submitted_args[0]))
        self.assertTrue(any(c.endswith("validate_extractions.sbatch") for c in submitted_args[1]))
        self.assertIn("--dependency=afterany:101", submitted_args[1])

    def test_no_jobs_when_everything_already_extracted(self):
        proc_a = self.tmp / "session_a" / "proc"
        proc_a.mkdir(parents=True)
        (proc_a / "results_00.yaml").write_text("complete: true\n")

        with mock.patch.object(subprocess, "run") as mock_run:
            job_ids = submit_moseq.submit_extraction(str(self.tmp))

        self.assertEqual(job_ids, [])
        mock_run.assert_not_called()


class TestSubmitKappaScan(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_builds_expected_args_with_defaults(self):
        captured = []

        def fake_run(cmd, **kwargs):
            captured.extend(cmd)
            return fake_sbatch_result("42")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            job_id = submit_moseq.submit_kappa_scan(str(self.tmp))

        self.assertEqual(job_id, "42")
        # positional args after the script: project_root, n_models, scan_scale,
        # min_kappa(""), max_kappa(""), num_iter
        script_index = next(i for i, c in enumerate(captured) if c.endswith("kappa_scan.sbatch"))
        tail = captured[script_index + 1:]
        self.assertEqual(tail, [str(self.tmp.resolve()), "10", "log", "", "", "100"])

    def test_passes_through_min_max_kappa_when_given(self):
        captured = []

        def fake_run(cmd, **kwargs):
            captured.extend(cmd)
            return fake_sbatch_result("43")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            submit_moseq.submit_kappa_scan(
                str(self.tmp), n_models=5, min_kappa=1000.0, max_kappa=1000000.0
            )

        script_index = next(i for i, c in enumerate(captured) if c.endswith("kappa_scan.sbatch"))
        tail = captured[script_index + 1:]
        self.assertEqual(tail, [str(self.tmp.resolve()), "5", "log", "1000.0", "1000000.0", "100"])

    def test_dependency_flags_passed_through(self):
        captured = []

        def fake_run(cmd, **kwargs):
            captured.extend(cmd)
            return fake_sbatch_result("44")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            submit_moseq.submit_kappa_scan(str(self.tmp), depends_on=["1", "2"])

        self.assertIn("--dependency=afterok:1:2", captured)


class TestSubmitLearnModel(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_builds_expected_args_with_defaults(self):
        captured = []

        def fake_run(cmd, **kwargs):
            captured.extend(cmd)
            return fake_sbatch_result("50")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            job_id = submit_moseq.submit_learn_model(str(self.tmp), kappa=50000.0)

        self.assertEqual(job_id, "50")
        script_index = next(i for i, c in enumerate(captured) if c.endswith("learn_model.sbatch"))
        tail = captured[script_index + 1:]
        self.assertEqual(tail, [str(self.tmp.resolve()), "50000.0", "1000", "model.p"])

    def test_custom_dest_name_and_num_iter(self):
        captured = []

        def fake_run(cmd, **kwargs):
            captured.extend(cmd)
            return fake_sbatch_result("51")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            submit_moseq.submit_learn_model(
                str(self.tmp), kappa=75000.0, num_iter=200, dest_name="model_k75000.p"
            )

        script_index = next(i for i, c in enumerate(captured) if c.endswith("learn_model.sbatch"))
        tail = captured[script_index + 1:]
        self.assertEqual(tail, [str(self.tmp.resolve()), "75000.0", "200", "model_k75000.p"])


class TestSubmitFullPipelineChaining(unittest.TestCase):
    """
    submit_full_pipeline() should chain every stage via --dependency=afterok on
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
            result = submit_moseq.submit_full_pipeline(str(self.tmp))

        m_agg.assert_called_once_with(str(self.tmp), depends_on=["1", "2"], exclusive=False)
        m_fit.assert_called_once_with(str(self.tmp), None, depends_on=["3"], exclusive=False)
        m_apply.assert_called_once_with(str(self.tmp), None, depends_on=["4"], exclusive=False)
        m_cp.assert_called_once_with(str(self.tmp), None, depends_on=["5"], exclusive=False)
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

    def test_does_not_touch_modeling(self):
        # Modeling needs a kappa-selection decision between the scan and
        # the final fit, so submit_full_pipeline() must never call these two --
        # confirms the intentional gap documented in submit_full_pipeline()'s
        # docstring, not an accidental omission.
        with mock.patch.object(submit_moseq, "submit_extraction", return_value=[]), \
             mock.patch.object(submit_moseq, "submit_aggregate", return_value="1"), \
             mock.patch.object(submit_moseq, "submit_pca_fit", return_value="2"), \
             mock.patch.object(submit_moseq, "submit_pca_apply", return_value="3"), \
             mock.patch.object(submit_moseq, "submit_compute_changepoints", return_value="4"), \
             mock.patch.object(submit_moseq, "submit_kappa_scan") as m_kappa, \
             mock.patch.object(submit_moseq, "submit_learn_model") as m_learn:
            submit_moseq.submit_full_pipeline(str(self.tmp))

        m_kappa.assert_not_called()
        m_learn.assert_not_called()

    def test_aggregate_gets_no_dependency_when_extraction_submits_nothing(self):
        with mock.patch.object(submit_moseq, "submit_extraction", return_value=[]), \
             mock.patch.object(submit_moseq, "submit_aggregate", return_value="1") as m_agg, \
             mock.patch.object(submit_moseq, "submit_pca_fit", return_value="2"), \
             mock.patch.object(submit_moseq, "submit_pca_apply", return_value="3"), \
             mock.patch.object(submit_moseq, "submit_compute_changepoints", return_value="4"):
            submit_moseq.submit_full_pipeline(str(self.tmp))

        m_agg.assert_called_once_with(str(self.tmp), depends_on=None, exclusive=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
