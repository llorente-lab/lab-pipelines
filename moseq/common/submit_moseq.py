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

Modeling (moseq2-model): learn-model has NO --cluster-type flag at all
(confirmed from its actual cli.py), it's always synchronous/local, so
there's no nested-Slurm question for submit_learn_model() regardless of
how the job itself was scheduled. kappa-scan does have the same
local/slurm switch PCA does, so submit_kappa_scan() follows the same
--cluster-type local-inside-one-job pattern. Also worth noting: unlike
extract/pca, moseq2-model's CLI has no --config-file support at all --
every modeling parameter is a plain CLI flag/default, nothing is read from
config.yaml here.

All jobs currently target the lab's single `illorent` node, requested
`--exclusive` at full size (256 cpus / 1500G, matching that node's actual
spec) -- there's only one such node, so per-stage resource tiering isn't
meaningful yet (a "small" job would still hold the whole node exclusively).
Practical consequence worth knowing: with one exclusive node, jobs run
strictly one at a time regardless of stage, so submit_extraction()'s
one-job-per-session parallelism doesn't get concurrent execution today --
it queues sequentially. Revisit stage-tiered resource requests once there's
more than one node.

Deliberately NOT using `--cleanenv` on apptainer_exec/apptainer_python (see
env_setup.sh) -- our whole env-var architecture (MOSEQ_SIF, RCLONE_CONFIG,
JUPYTER_PATH, ...) depends on Apptainer's default host-env inheritance.
Switching to --cleanenv now would mean re-auditing and re-passing every
implicitly-relied-on var via --env, duplicating already-done work for no
real benefit, and would diverge from Miniscope's identical pattern.

Deferred, noted for later (not forgotten, just not needed yet):
- Elastic/multi-node PCA/model fitting via dask-jobqueue's or kappa-scan's
  real Slurm cluster type, once nested Slurm-from-inside-Apptainer has
  actually been tested and confirmed safe, AND once there's more than one
  node to make elastic scaling meaningful.
- Resource allocation/sharing across pipelines (Miniscope + Moseq
  competing for the same partition/queue) -- explicitly out of scope for
  this module, belongs to a future cross-pipeline resource-management
  layer per the original architecture discussion.
- "Best model" auto-selection after a kappa scan (matching against the
  model-free changepoint duration distribution) -- not implemented here.
  submit_kappa_scan() only trains the batch of models; picking a winner
  and feeding it into a final submit_learn_model() call is a separate,
  not-yet-built step. submit_master() deliberately does NOT chain into
  kappa-scan/learn-model for this reason -- modeling still needs an
  explicit, separate call.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from reconcile_moseq_extraction import sessions_needing_extraction

MOSEQ_ROOT_DIR = Path(__file__).resolve().parent.parent
EXTRACT_DIR = MOSEQ_ROOT_DIR / "extract"
PCA_DIR = MOSEQ_ROOT_DIR / "pca"
MODEL_DIR = MOSEQ_ROOT_DIR / "model"

_JOB_ID_RE = re.compile(r"Submitted batch job (\d+)")


def _log_flags(project_root: str, stage: str) -> list[str]:
    """
    --output/--error as explicit sbatch CLI flags, computed per project at
    submission time, rather than baked into each .sbatch file as a static
    #SBATCH comment. Two reasons this has to happen here, in Python, not in
    the script:

    1. project_root isn't known until submission time (it's passed as $1
       to a shared, generic template), so a static #SBATCH --output line
       in the script can't reference it at all.
    2. Slurm's own precedence order is: command-line flag > environment
       variable > #SBATCH directive in the script. So even if we baked a
       path into the script, an SBATCH_OUTPUT/SBATCH_ERROR env var (like
       Miniscope's env_setup.sh sets, globally, for its own logging
       convention) would silently win and override it. Passing --output/
       --error as actual sbatch command-line flags is the only reliable
       way to guarantee Moseq's per-project log path actually takes
       effect regardless of what's exported in the calling shell.

    Logs land in <project_root>/slurm_logs/, inside the project itself
    (not a global $SCRATCH/logs/ tree), so they're discoverable alongside
    everything else that project produced. The directory is created here,
    synchronously, before sbatch runs -- sbatch fails immediately if the
    output directory doesn't already exist when it tries to open the file.
    """
    log_dir = Path(project_root) / "slurm_logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    return [
        f"--output={log_dir}/{stage}-%j.out",
        f"--error={log_dir}/{stage}-%j.err",
    ]


def _sbatch(
    script: Path,
    *positional_args: str,
    sbatch_flags: list[str] | None = None,
) -> str:
    """
    Submit one job via sbatch, return its job ID as a string. sbatch_flags
    (e.g. ["--dependency=afterok:123:456", "--output=..."]) must come
    before the script path on the command line, positional_args are passed
    through to the script itself ($1, $2, ... inside it) -- these two are
    NOT interchangeable, sbatch does not accept flags after the script path.
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


def _dependency_flags(depends_on: list[str] | None) -> list[str]:
    if not depends_on:
        return []
    return [f"--dependency=afterok:{':'.join(depends_on)}"]


def _mail_flags() -> list[str]:
    """--mail-type=FAIL if PIPELINE_NOTIFY_EMAIL is set; no-op otherwise."""
    email = os.environ.get("PIPELINE_NOTIFY_EMAIL", "").strip()
    if not email:
        return []
    return ["--mail-type=FAIL", f"--mail-user={email}"]


def _sbatch_flags(project_root: str, stage: str, depends_on: list[str] | None) -> list[str]:
    """Every submit_* function's sbatch_flags is this same combination."""
    return _log_flags(project_root, stage) + _dependency_flags(depends_on) + _mail_flags()


def submit_extraction(project_root: str, config_file: str | None = None) -> list[str]:
    """
    One sbatch job for the whole project (extract.sbatch loops over all
    sessions needing extraction internally). Returns a single-element list
    containing the job ID, or an empty list if nothing needs extraction.
    The list return type is kept so submit_master()'s --dependency=afterok
    chaining works unchanged.
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")

    if not sessions_needing_extraction(project_root):
        return []

    script = EXTRACT_DIR / "extract.sbatch"
    return [
        _sbatch(
            script, project_root, config_file,
            sbatch_flags=_sbatch_flags(project_root, "extract", None),
        )
    ]


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
    return _sbatch(
        script, project_root,
        sbatch_flags=_sbatch_flags(project_root, "aggregate", depends_on),
    )


def submit_pca_fit(
    project_root: str,
    config_file: str | None = None,
    depends_on: list[str] | None = None,
) -> str:
    """Fits PCA across the whole aggregated session batch (see pca_fit.sbatch)."""
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    script = PCA_DIR / "pca_fit.sbatch"
    return _sbatch(
        script, project_root, config_file,
        sbatch_flags=_sbatch_flags(project_root, "pca_fit", depends_on),
    )


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
        script, project_root, config_file, pca_file,
        sbatch_flags=_sbatch_flags(project_root, "pca_apply", depends_on),
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
        sbatch_flags=_sbatch_flags(project_root, "changepoints", depends_on),
    )


def submit_kappa_scan(
    project_root: str,
    n_models: int = 10,
    scan_scale: str = "log",
    min_kappa: float | None = None,
    max_kappa: float | None = None,
    num_iter: int = 100,
    depends_on: list[str] | None = None,
) -> str:
    """
    Trains n_models models scanning kappa (see kappa_scan.sbatch), one
    driver job using moseq2-model's own --cluster-type local (models
    trained sequentially inside this job's allocation, not one Slurm job
    per model -- same simplicity tradeoff already made for PCA). Does NOT
    pick a winner -- that's a separate, not-yet-built step. num_iter
    defaults to moseq2-model's own scan default (100), deliberately lower
    than a final model's iteration count, since this is exploratory.
    """
    project_root = str(Path(project_root).resolve())
    script = MODEL_DIR / "kappa_scan.sbatch"
    args = [
        project_root,
        str(n_models),
        scan_scale,
        str(min_kappa) if min_kappa is not None else "",
        str(max_kappa) if max_kappa is not None else "",
        str(num_iter),
    ]
    return _sbatch(
        script, *args, sbatch_flags=_sbatch_flags(project_root, "kappa_scan", depends_on)
    )


def submit_learn_model(
    project_root: str,
    kappa: float,
    num_iter: int = 1000,
    dest_name: str = "model.p",
    depends_on: list[str] | None = None,
) -> str:
    """
    Trains a single final model at a chosen kappa (see learn_model.sbatch).
    learn-model has no --cluster-type flag at all, so this is always
    synchronous/local from moseq2-model's own CLI regardless -- no nested-
    Slurm question here. num_iter defaults to 1000, matching moseq2's own
    guidance for a final (non-exploratory) model fit.
    """
    project_root = str(Path(project_root).resolve())
    script = MODEL_DIR / "learn_model.sbatch"
    return _sbatch(
        script,
        project_root,
        str(kappa),
        str(num_iter),
        dest_name,
        sbatch_flags=_sbatch_flags(project_root, "learn_model", depends_on),
    )


def submit_master(project_root: str, config_file: str | None = None) -> dict:
    """
    Chains everything currently implemented: extraction (per session) ->
    aggregate -> pca-fit -> pca-apply -> compute-changepoints, each stage
    gated on the previous one via --dependency=afterok. Modeling
    (kappa-scan / learn-model) is intentionally NOT included -- picking a
    winning kappa from a scan needs a decision (human or an auto-selection
    step not yet built) between the scan and the final fit, so it can't be
    blindly chained the way the fully-automatable stages above are. Call
    submit_kappa_scan()/submit_learn_model() separately once changepoints
    are in.

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
