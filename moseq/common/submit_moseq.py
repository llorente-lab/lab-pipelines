"""
Submission module for the Moseq pipeline: builds and fires SLURM jobs via
sbatch. Called from both the project notebook's cells and `run moseq` CLI
subcommands -- both front doors call these exact functions, so submission
logic is never duplicated between the notebook and CLI paths.

Deliberately does NOT use moseq2-extract's or moseq2-pca's own
--cluster-type slurm machinery (dask-jobqueue for PCA/changepoints,
run_slurm_extract for extraction). That machinery calls `sbatch` itself
from *inside* whatever process runs it -- for us, that would mean calling
sbatch from inside the Apptainer container, which is untested and would
need Slurm's client binaries and the munge auth socket reachable inside
the container's filesystem.

To sidestep that entirely: this module always submits jobs itself from the
host process (same pattern as Miniscope's cli/run calling `sbatch
motion_correction.sbatch`), and every moseq2 CLI invocation *inside* a job
always runs with --cluster-type local (using the cores that job's own
sbatch allocation was given), never slurm. Confirmed with the user this is
the right tradeoff for now.

Deferred, noted for later (not forgotten, just not needed yet):
- Elastic/multi-node PCA fitting via dask-jobqueue's real Slurm cluster
  type, once nested Slurm-from-inside-Apptainer has actually been tested
  and confirmed safe.
- Resource allocation/sharing across pipelines (Miniscope + Moseq
  competing for the same partition/queue) -- explicitly out of scope for
  this module, belongs to a future cross-pipeline resource-management
  layer per the original architecture discussion.
- Modeling (kappa-scan / learn-model) submission -- moseq2-model's actual
  CLI hasn't been inspected yet (only moseq2-extract's and moseq2-pca's
  have), so submit_kappa_scan()/submit_model() are intentionally not
  implemented here. Do not guess at the CLI shape; check the real
  cli.py first, the same way this file's PCA/extraction functions were
  built against moseq2-extract's and moseq2-pca's actual cli.py.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

from reconcile_moseq_extraction import sessions_needing_extraction

MOSEQ_ROOT_DIR = Path(__file__).resolve().parent.parent
EXTRACT_DIR = MOSEQ_ROOT_DIR / "extract"
PCA_DIR = MOSEQ_ROOT_DIR / "pca"

_JOB_ID_RE = re.compile(r"Submitted batch job (\d+)")


def _sbatch(script: Path, *positional_args: str, sbatch_flags: list[str] | None = None) -> str:
    """
    Submit one job via sbatch, return its job ID as a string. sbatch_flags
    (e.g. ["--dependency=afterok:123:456"]) must come before the script
    path on the command line, positional_args are passed through to the
    script itself ($1, $2, ... inside it) -- these two are NOT
    interchangeable, sbatch does not accept flags after the script path.
    """
    cmd = ["sbatch", *(sbatch_flags or []), str(script), *positional_args]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    match = _JOB_ID_RE.search(result.stdout)
    if not match:
        raise RuntimeError(
            f"sbatch succeeded (exit 0) but didn't return a recognizable job ID. "
            f"stdout was: {result.stdout!r}"
        )
    return match.group(1)


def _dependency_flags(depends_on: list[str] | None) -> list[str] | None:
    if not depends_on:
        return None
    return [f"--dependency=afterok:{':'.join(depends_on)}"]


def submit_extraction(project_root: str, config_file: str | None = None) -> list[str]:
    """
    One sbatch job per session still needing extraction, per
    reconcile_moseq_extraction.sessions_needing_extraction() -- the exact
    same check `run moseq queue` reports, so this can never submit a
    session reconciliation already considers done. Returns the list of
    submitted job IDs (empty list if nothing needed extraction).
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    script = EXTRACT_DIR / "extract_session.sbatch"

    job_ids = []
    for session_name in sessions_needing_extraction(project_root):
        session_dir = str(Path(project_root) / session_name)
        job_ids.append(_sbatch(script, session_dir, config_file))
    return job_ids


def submit_aggregate(project_root: str, depends_on: list[str] | None = None) -> str:
    """
    Consolidates every session's proc/ output into aggregate_results/ and
    (re)generates moseq2-index.yaml. Pass the job IDs from
    submit_extraction() as depends_on to chain this so it only runs once
    every extraction job in the batch has actually succeeded
    (--dependency=afterok), rather than racing ahead of still-running
    extractions.
    """
    project_root = str(Path(project_root).resolve())
    script = EXTRACT_DIR / "aggregate.sbatch"
    return _sbatch(script, project_root, sbatch_flags=_dependency_flags(depends_on))


def submit_pca_fit(
    project_root: str,
    config_file: str | None = None,
    depends_on: list[str] | None = None,
) -> str:
    """Fits PCA across the whole aggregated session batch (see pca_fit.sbatch)."""
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    script = PCA_DIR / "pca_fit.sbatch"
    return _sbatch(script, project_root, config_file, sbatch_flags=_dependency_flags(depends_on))


def submit_pca_apply(
    project_root: str,
    config_file: str | None = None,
    pca_file: str | None = None,
    depends_on: list[str] | None = None,
) -> str:
    """
    Projects extracted sessions onto an already-fit PCA basis (see
    pca_apply.sbatch). This is also the job to (re)run, cheaply, whenever
    new sessions are added to an existing project -- no PCA refit needed.
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    pca_file = pca_file or str(Path(project_root) / "_pca" / "pca.h5")
    script = PCA_DIR / "pca_apply.sbatch"
    return _sbatch(
        script, project_root, config_file, pca_file, sbatch_flags=_dependency_flags(depends_on)
    )


def submit_compute_changepoints(
    project_root: str,
    config_file: str | None = None,
    pca_file_components: str | None = None,
    pca_file_scores: str | None = None,
    depends_on: list[str] | None = None,
) -> str:
    """
    Model-free syllable changepoints from PCA scores (see
    compute_changepoints.sbatch). Optional in moseq2's own workflow, but
    useful as the target-duration reference for kappa selection later, so
    it's included in the default submit_master() chain below.
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    pca_file_components = pca_file_components or str(Path(project_root) / "_pca" / "pca.h5")
    pca_file_scores = pca_file_scores or str(Path(project_root) / "_pca" / "pca_scores.h5")
    script = PCA_DIR / "compute_changepoints.sbatch"
    return _sbatch(
        script,
        project_root,
        config_file,
        pca_file_components,
        pca_file_scores,
        sbatch_flags=_dependency_flags(depends_on),
    )


def submit_master(project_root: str, config_file: str | None = None) -> dict:
    """
    Chains everything currently implemented: extraction (per session) ->
    aggregate -> pca-fit -> pca-apply -> compute-changepoints, each stage
    gated on the previous one via --dependency=afterok. Modeling
    (kappa-scan / learn-model) is not included yet -- see this module's
    docstring for why -- so this chain currently stops after changepoints,
    not a true end-to-end run.

    Returns a dict of stage name -> job ID(s) so a caller (CLI or
    notebook) can print/track them, e.g. via `run moseq status` or
    `run moseq logs`.
    """
    extraction_jobs = submit_extraction(project_root, config_file)
    aggregate_job = submit_aggregate(project_root, depends_on=extraction_jobs or None)
    pca_fit_job = submit_pca_fit(project_root, config_file, depends_on=[aggregate_job])
    pca_apply_job = submit_pca_apply(project_root, config_file, depends_on=[pca_fit_job])
    changepoints_job = submit_compute_changepoints(
        project_root, config_file, depends_on=[pca_apply_job]
    )
    return {
        "extraction": extraction_jobs,
        "aggregate": aggregate_job,
        "pca_fit": pca_fit_job,
        "pca_apply": pca_apply_job,
        "compute_changepoints": changepoints_job,
    }
