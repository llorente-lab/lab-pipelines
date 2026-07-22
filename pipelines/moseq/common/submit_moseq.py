"""Slurm job submission for the Moseq pipeline."""

import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from reconcile_moseq import sessions_needing_extraction

MOSEQ_ROOT_DIR = Path(__file__).resolve().parent.parent
EXTRACT_DIR = MOSEQ_ROOT_DIR / "extract"
PCA_DIR = MOSEQ_ROOT_DIR / "pca"
MODEL_DIR = MOSEQ_ROOT_DIR / "model"

_CLI_DIR = MOSEQ_ROOT_DIR.parent.parent / "cli"
_MOSEQ_REGISTRY = MOSEQ_ROOT_DIR / "resources.yaml"

# Matches both real sbatch output and --test-only dry-run output.
_JOB_ID_RE = re.compile(r"Submitted batch job (\d+)|sbatch: Job (\d+) to start at")

# Cap on extraction array tasks -- a project with hundreds of sessions
# shouldn't spawn hundreds of jobs. Sessions are split into at most this
# many batches, and each array task works through its batch sequentially.
MAX_EXTRACT_ARRAY_SIZE = 6


def _batch_sessions(sessions, max_batches=MAX_EXTRACT_ARRAY_SIZE):
    """
    Split sessions into at most max_batches groups (round-robin, so batch
    sizes differ by at most one), so a job array fans out to a capped
    number of tasks instead of one task per session.

    sessions (list of str): session names needing extraction.
    max_batches (int): upper bound on number of array tasks.

    Returns a list of lists of str, one list per batch (non-empty).
    """
    n_batches = min(len(sessions), max_batches)
    batches = [[] for _ in range(n_batches)]
    for i, session in enumerate(sessions):
        batches[i % n_batches].append(session)
    return batches


def _resource_flags(stage, metadata=None, exclusive=False, cores=None, mem_gb=None, time=None):
    """
    Thin wrapper around estimate_resources.resource_flags() -- the one
    implementation of the exclusive/cores/mem/time -> sbatch-flag logic,
    also used by miniscope's bash CLI (see cli/resources.sh). Falls back to
    just the explicit overrides if the estimator/registry is missing.

    stage (str): resources.yaml stage key.
    metadata (dict or None): values the stage's formulas can reference.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns a list of str, the sbatch flags.
    """
    if _CLI_DIR.exists() and _MOSEQ_REGISTRY.exists():
        cli_dir = str(_CLI_DIR)
        if cli_dir not in sys.path:
            sys.path.insert(0, cli_dir)
        try:
            from estimate_resources import resource_flags
            return resource_flags(
                str(_MOSEQ_REGISTRY), stage, metadata or {},
                exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
            )
        except Exception:
            pass

    flags = []
    if exclusive:
        flags.append("--exclusive")
    if cores is not None:
        flags.append(f"--cpus-per-task={cores}")
    if mem_gb is not None:
        flags.append(f"--mem={mem_gb}G")
    if time:
        flags.append(f"--time={time}")
    return flags


def _count_aggregate_sessions(project_root):
    """
    project_root (str): project's root directory.

    Returns an int (number of .h5 files in aggregate_results/), or None if
    that directory doesn't exist yet.
    """
    agg = Path(project_root) / "aggregate_results"
    if not agg.is_dir():
        return None
    return len(list(agg.glob("*.h5")))


def _log_flags(project_root, stage):
    """
    project_root (str): project's root directory.
    stage (str): stage name, used in the log filename.

    Returns a list of str: --output/--error flags pointing to
    <project_root>/slurm_logs/.
    """
    log_dir = Path(project_root) / "slurm_logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    return [
        f"--output={log_dir}/{stage}-%j.out",
        f"--error={log_dir}/{stage}-%j.err",
    ]


def _record_job(project_root, stage, job_id):
    """
    Append one line to <project_root>/status/jobs.jsonl -- read by
    `run moseq dashboard` (common/dashboard.py) and cross-referenced
    against live squeue state / history.jsonl.

    project_root (str): project's root directory.
    stage (str): stage name.
    job_id (str): Slurm job ID.
    """
    status_dir = Path(project_root) / "status"
    status_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "job_id": job_id,
        "stage": stage,
        "submitted_at": datetime.now().isoformat(timespec="seconds"),
    }
    with open(status_dir / "jobs.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")


def _sbatch(script, *positional_args, sbatch_flags=None, record_job=None):
    """
    Submit one job via sbatch, return its job ID.

    script (Path): the .sbatch script to submit.
    positional_args (str): positional args passed through to the script.
    sbatch_flags (list of str or None): extra flags passed to sbatch.
    record_job (tuple of (str, str) or None): (project_root, stage) -- if
        given, the submission is also appended to that project's
        status/jobs.jsonl.

    Returns the job ID (str).
    """
    cmd = ["sbatch", *(sbatch_flags or []), str(script), *positional_args]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"sbatch rejected this submission (exit {e.returncode}): {e.stderr.strip() or e.stdout.strip()}"
        ) from e
    # --test-only prints to stderr, not stdout -- check both.
    match = _JOB_ID_RE.search(result.stdout) or _JOB_ID_RE.search(result.stderr)
    if not match:
        raise RuntimeError(
            f"sbatch succeeded (exit 0) but didn't return a recognizable job ID. "
            f"stdout was: {result.stdout!r}, stderr was: {result.stderr!r}"
        )
    job_id = match.group(1) or match.group(2)
    if record_job is not None:
        _record_job(record_job[0], record_job[1], job_id)
    return job_id


def _dependency_flags(depends_on):
    """depends_on (list of str or None): job IDs to depend on. Returns a list of str."""
    if not depends_on:
        return []
    return [f"--dependency=afterok:{':'.join(depends_on)}"]


def _mail_flags():
    """Returns a list of str: --mail-type=FAIL flags if PIPELINE_NOTIFY_EMAIL is set."""
    email = os.environ.get("PIPELINE_NOTIFY_EMAIL", "").strip()
    if not email:
        return []
    return ["--mail-type=FAIL", f"--mail-user={email}"]


def _sbatch_flags(project_root, stage, depends_on):
    """
    project_root (str): project's root directory.
    stage (str): stage name.
    depends_on (list of str or None): job IDs to depend on.

    Returns a list of str: log + dependency + mail flags combined.
    """
    return _log_flags(project_root, stage) + _dependency_flags(depends_on) + _mail_flags()


def _submit_stage(
    script,
    project_root,
    *positional_args,
    log_stage,
    resource_stage,
    metadata=None,
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Shared shape behind every non-extraction submit_* function below:
    resolve sbatch flags (logs + dependency + mail + resources) and submit.

    script (Path): the .sbatch script to submit.
    project_root (str): project's root directory.
    positional_args (str): positional args passed through to the script.
    log_stage (str): stage name used for the log filename and jobs.jsonl.
    resource_stage (str): resources.yaml key for this stage -- differs
        from log_stage for a couple of stages (e.g. "pca_fit" vs "pca-fit").
    metadata (dict or None): values the stage's resource formulas can use.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    return _sbatch(
        script, *positional_args,
        sbatch_flags=_sbatch_flags(project_root, log_stage, depends_on)
        + _resource_flags(resource_stage, metadata, exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time),
        record_job=(project_root, log_stage),
    )


def submit_extraction(
    project_root,
    config_file=None,
    use_array=True,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Submit extraction jobs. exclusive is ignored here: extraction always
    targets the shared normal partition regardless.

    project_root (str): project's root directory.
    config_file (str or None): path to config.yaml, defaults to
        <project_root>/config.yaml. Must already exist -- the caller
        (cli/pipelines/moseq.sh) generates it before calling this, since
        generating it here, once per array task, would race.
    use_array (bool): submit as a batched Slurm job array (each task works
        through a chunk of sessions sequentially) instead of a single job.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns a list of job ID strings for dependency chaining, or [] if
    nothing needs extracting.
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    if not Path(config_file).exists():
        raise RuntimeError(
            f"{config_file} doesn't exist -- generate it before calling "
            f"submit_extraction (see the 'extract' case in cli/pipelines/moseq.sh)"
        )

    sessions = sessions_needing_extraction(project_root)
    if not sessions:
        return []

    res = _resource_flags("extract", {"n_sessions": len(sessions)}, cores=cores, mem_gb=mem_gb, time=time)

    if not use_array:
        script = EXTRACT_DIR / "extract.sbatch"
        return [
            _sbatch(
                script, project_root, config_file,
                sbatch_flags=_sbatch_flags(project_root, "extract", None) + res,
                record_job=(project_root, "extract"),
            )
        ]

    batches = _batch_sessions(sessions)

    status_dir = Path(project_root) / "status"
    status_dir.mkdir(parents=True, exist_ok=True)
    sessions_file = status_dir / "extract_sessions.txt"
    # One line per batch, sessions space-separated within a line -- each
    # array task reads its own line and works through it sequentially.
    sessions_file.write_text("\n".join(" ".join(batch) for batch in batches) + "\n")

    log_dir = Path(project_root) / "slurm_logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    # %A/%a per-task log files instead of %j, so tasks don't overwrite each other.
    array_log_flags = [
        f"--output={log_dir}/extract-%A-%a.out",
        f"--error={log_dir}/extract-%A-%a.err",
    ]

    job_id = _sbatch(
        EXTRACT_DIR / "extract_array.sbatch",
        project_root, str(sessions_file), config_file,
        sbatch_flags=[
            *array_log_flags,
            f"--array=0-{len(batches) - 1}",
            *_dependency_flags(None),
            *_mail_flags(),
            *res,
        ],
        record_job=(project_root, "extract"),
    )

    # afterany so validation runs and reports on partial failures too.
    _sbatch(
        EXTRACT_DIR / "validate_extractions.sbatch",
        project_root,
        sbatch_flags=_log_flags(project_root, "validate_extractions")
        + [f"--dependency=afterany:{job_id}"]
        + _mail_flags(),
        record_job=(project_root, "validate_extractions"),
    )

    return [job_id]


def submit_aggregate(
    project_root,
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Consolidate session proc/ outputs into aggregate_results/ and
    regenerate moseq2-index.yaml.

    project_root (str): project's root directory.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    project_root = str(Path(project_root).resolve())
    return _submit_stage(
        EXTRACT_DIR / "aggregate.sbatch", project_root, project_root,
        log_stage="aggregate", resource_stage="aggregate", depends_on=depends_on,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    )


def submit_pca_fit(
    project_root,
    config_file=None,
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Fit PCA across the aggregated session batch.

    project_root (str): project's root directory.
    config_file (str or None): path to config.yaml, defaults to
        <project_root>/config.yaml.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    n = _count_aggregate_sessions(project_root)
    return _submit_stage(
        PCA_DIR / "pca_fit.sbatch", project_root, project_root, config_file,
        log_stage="pca_fit", resource_stage="pca-fit",
        metadata={"n_sessions": n} if n is not None else {}, depends_on=depends_on,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    )


def submit_pca_apply(
    project_root,
    config_file=None,
    pca_file=None,
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Project extracted sessions onto an already-fit PCA basis.

    project_root (str): project's root directory.
    config_file (str or None): path to config.yaml, defaults to
        <project_root>/config.yaml.
    pca_file (str or None): path to pca.h5, defaults to
        <project_root>/_pca/pca.h5.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    pca_file = pca_file or str(Path(project_root) / "_pca" / "pca.h5")
    n = _count_aggregate_sessions(project_root)
    return _submit_stage(
        PCA_DIR / "pca_apply.sbatch", project_root, project_root, config_file, pca_file,
        log_stage="pca_apply", resource_stage="pca-apply",
        metadata={"n_sessions": n} if n is not None else {}, depends_on=depends_on,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    )


def submit_compute_changepoints(
    project_root,
    config_file=None,
    pca_file_components=None,
    pca_file_scores=None,
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Compute model-free syllable changepoints from PCA scores.

    project_root (str): project's root directory.
    config_file (str or None): path to config.yaml, defaults to
        <project_root>/config.yaml.
    pca_file_components (str or None): path to pca.h5, defaults to
        <project_root>/_pca/pca.h5.
    pca_file_scores (str or None): path to pca_scores.h5, defaults to
        <project_root>/_pca/pca_scores.h5.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    pca_file_components = pca_file_components or str(Path(project_root) / "_pca" / "pca.h5")
    pca_file_scores = pca_file_scores or str(Path(project_root) / "_pca" / "pca_scores.h5")
    n = _count_aggregate_sessions(project_root)
    return _submit_stage(
        PCA_DIR / "compute_changepoints.sbatch", project_root,
        project_root, config_file, pca_file_components, pca_file_scores,
        log_stage="changepoints", resource_stage="changepoints",
        metadata={"n_sessions": n} if n is not None else {}, depends_on=depends_on,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    )


def submit_kappa_scan(
    project_root,
    n_models=10,
    scan_scale="log",
    min_kappa=None,
    max_kappa=None,
    num_iter=100,
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Train n_models models across a kappa range in a single job; does not
    select a winner.

    project_root (str): project's root directory.
    n_models (int): number of models to scan.
    scan_scale (str): "log" or "linear" spacing across the kappa range.
    min_kappa (float or None): lower bound of the kappa range.
    max_kappa (float or None): upper bound of the kappa range.
    num_iter (int): training iterations per model.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    project_root = str(Path(project_root).resolve())
    args = [
        project_root,
        str(n_models),
        scan_scale,
        str(min_kappa) if min_kappa is not None else "",
        str(max_kappa) if max_kappa is not None else "",
        str(num_iter),
    ]
    return _submit_stage(
        MODEL_DIR / "kappa_scan.sbatch", project_root, *args,
        log_stage="kappa_scan", resource_stage="kappa-scan",
        metadata={"n_models": n_models, "num_iter": num_iter}, depends_on=depends_on,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    )


def submit_learn_model(
    project_root,
    kappa,
    num_iter=1000,
    dest_name="model.p",
    depends_on=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Train a single final model at a chosen kappa.

    project_root (str): project's root directory.
    kappa (float): the chosen kappa value.
    num_iter (int): training iterations.
    dest_name (str): filename for the trained model, written under
        <project_root>/models/.
    depends_on (list of str or None): job IDs this submission depends on.
    exclusive (bool): request the whole node.
    cores (int or None): explicit --cpus-per-task override.
    mem_gb (int or None): explicit --mem override in GB.
    time (str or None): explicit --time override.

    Returns the job ID (str).
    """
    project_root = str(Path(project_root).resolve())
    return _submit_stage(
        MODEL_DIR / "learn_model.sbatch", project_root,
        project_root, str(kappa), str(num_iter), dest_name,
        log_stage="learn_model", resource_stage="learn-model",
        metadata={"num_iter": num_iter}, depends_on=depends_on,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    )


def submit_full_pipeline(project_root, config_file=None, exclusive=False):
    """
    Chain extraction -> aggregate -> pca-fit -> pca-apply -> changepoints
    via afterok dependencies. Modeling (kappa-scan/learn-model) is excluded
    because kappa selection requires human review.

    project_root (str): project's root directory.
    config_file (str or None): path to config.yaml, defaults to
        <project_root>/config.yaml.
    exclusive (bool): request the whole node for every stage in the chain.

    Returns a dict mapping stage name to job ID(s) submitted for it.
    """
    extraction_jobs = submit_extraction(project_root, config_file)
    aggregate_job = submit_aggregate(
        project_root, depends_on=extraction_jobs or None, exclusive=exclusive
    )
    pca_fit_job = submit_pca_fit(
        project_root, config_file, depends_on=[aggregate_job], exclusive=exclusive
    )
    pca_apply_job = submit_pca_apply(
        project_root, config_file, depends_on=[pca_fit_job], exclusive=exclusive
    )
    changepoints_job = submit_compute_changepoints(
        project_root, config_file, depends_on=[pca_apply_job], exclusive=exclusive
    )
    return {
        "extraction": extraction_jobs,
        "aggregate": aggregate_job,
        "pca_fit": pca_fit_job,
        "pca_apply": pca_apply_job,
        "compute_changepoints": changepoints_job,
    }
