"""
Submission module for the Moseq pipeline
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

from reconcile_moseq_extraction import sessions_needing_extraction

MOSEQ_ROOT_DIR = Path(__file__).resolve().parent.parent
EXTRACT_DIR = MOSEQ_ROOT_DIR / "extract"
PCA_DIR = MOSEQ_ROOT_DIR / "pca"
MODEL_DIR = MOSEQ_ROOT_DIR / "model"

# MOSEQ_ROOT_DIR is repo_root/pipelines/moseq -- cli/ is a sibling of
# pipelines/ at the repo root, two levels up, not one. (Was one level up
# before the pipelines/ restructuring moved this whole directory down a
# level; --.parent alone silently resolved to pipelines/cli, which doesn't
# exist, so _resource_flags's _CLI_DIR.exists() gate was False the whole
# time post-restructuring -- every moseq submission was silently getting
# NO computed partition/cores/mem, falling back entirely to each
# .sbatch file's static #SBATCH defaults. Caught via _resource_flags
# actually being exercised directly while testing the cores/mem/time
# override feature.)
_CLI_DIR = MOSEQ_ROOT_DIR.parent.parent / "cli"
_MOSEQ_REGISTRY = MOSEQ_ROOT_DIR / "resources.yaml"

# Real sbatch prints "Submitted batch job <id>". `sbatch --test-only`
# (used by scripts/dryrun_resource_flags.sh to validate flag combinations
# without actually queuing anything) prints a differently-worded
# "sbatch: Job <id> to start at ..." instead -- match either, so a dry
# run doesn't spuriously raise here on a request Slurm actually accepted.
_JOB_ID_RE = re.compile(r"Submitted batch job (\d+)|sbatch: Job (\d+) to start at")


def _resource_flags(
    stage: str,
    metadata: dict | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
) -> list[str]:
    """
    Compute --partition/--cpus-per-task/--mem/--exclusive/--time from
    the registry. Returns [] gracefully if the estimator or registry is
    missing (still honoring exclusive/cores/mem_gb/time overrides, since
    those don't depend on the registry existing).

    exclusive=True is a caller-requested override (see submit_*'s own
    `exclusive` param), not something resources.yaml sets per stage --
    intended for someone with a genuinely huge dataset who wants to hand
    one expensive run the whole illorent node (illorent is a single node,
    so --exclusive there already means "all of illorent"). When set, the
    formula-derived --cpus-per-task/--mem are deliberately dropped rather
    than emitted alongside --exclusive: those numbers are calibrated for a
    TYPICAL run of this stage, and second-guessing an explicit whole-node
    request with a typical-run number would just be self-defeating. Slurm
    hands the job everything the node has instead.

    cores/mem_gb/time are separate, more surgical overrides -- someone who
    knows this specific run needs a specific number, not the whole node.
    When given, they ALWAYS win, even combined with exclusive=True (an
    unusual but valid combination: reserve the whole node, but still tell
    Slurm this job itself only wants part of it). time in particular has
    no registry equivalent at all -- resources.yaml/estimate_resources.py
    don't estimate wall time, so this is currently the only way to change
    a stage's wall time short of editing its .sbatch file's #SBATCH --time
    directive by hand.
    """
    result: dict = {}
    if _CLI_DIR.exists() and _MOSEQ_REGISTRY.exists():
        cli_dir = str(_CLI_DIR)
        if cli_dir not in sys.path:
            sys.path.insert(0, cli_dir)
        try:
            from estimate_resources import estimate
            result = estimate(str(_MOSEQ_REGISTRY), stage, metadata or {})
        except Exception:
            result = {}

    flags: list[str] = []
    if result.get("partition"):
        flags.append(f"--partition={result['partition']}")
    if exclusive:
        flags.append("--exclusive")

    c = cores if cores is not None else (None if exclusive else result.get("cores"))
    m = mem_gb if mem_gb is not None else (None if exclusive else result.get("mem_gb"))
    if c is not None:
        flags.append(f"--cpus-per-task={c}")
    if m is not None:
        flags.append(f"--mem={m}G")
    if not exclusive and result.get("exclusive"):
        flags.append("--exclusive")

    if time:
        flags.append(f"--time={time}")
    return flags


def _count_aggregate_sessions(project_root: str) -> int | None:
    agg = Path(project_root) / "aggregate_results"
    if not agg.is_dir():
        return None
    return len(list(agg.glob("*.h5")))


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
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        # A genuine rejection (bad --time, resource request that doesn't
        # fit the partition's MaxWall, etc.) -- sbatch's own
        # stderr says exactly why, but the default CalledProcessError
        # traceback doesn't include it, just "returned non-zero exit
        # status N". Re-raise with the actual message attached so a
        # rejection is diagnosable instead of just "something failed".
        raise RuntimeError(
            f"sbatch rejected this submission (exit {e.returncode}): {e.stderr.strip() or e.stdout.strip()}"
        ) from e
    # Real sbatch prints "Submitted batch job <id>" to stdout. `--test-only`
    # (see scripts/dryrun_resource_flags.sh) prints its "Job <id> to start
    # at ..." message to STDERR instead, confirmed empirically -- a
    # stdout-only search always failed under --test-only even on a request
    # Slurm actually accepted. Search both.
    match = _JOB_ID_RE.search(result.stdout) or _JOB_ID_RE.search(result.stderr)
    if not match:
        raise RuntimeError(
            f"sbatch succeeded (exit 0) but didn't return a recognizable job ID. "
            f"stdout was: {result.stdout!r}, stderr was: {result.stderr!r}"
        )
    # group(1) = real submission's "Submitted batch job N", group(2) =
    # --test-only's "Job N to start at" -- exactly one of the two is set,
    # whichever branch of the alternation matched.
    return match.group(1) or match.group(2)


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


def submit_extraction(
    project_root: str,
    config_file: str | None = None,
    use_array: bool = True,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
) -> list[str]:
    """
    Submit extraction jobs. Returns job ID(s) as a list (for dependency
    chaining), or an empty list if nothing needs extraction.

    use_array=True (default): one array task per session (extract_array.sbatch).
        Each task gets its own log and status file; a single failure doesn't
        abort the rest. The sessions list is written to
        <project_root>/status/extract_sessions.txt before submission so each
        array task can index into it. Logs land at
        <project_root>/slurm_logs/extract-<array_job_id>-<task_id>.out.
        Returns a single-element list (the array job ID); --dependency=afterok
        on an array job ID waits for all tasks to succeed, which is exactly
        what submit_master()'s chain to aggregate needs.

    use_array=False: one job looping all sessions sequentially
        (extract.sbatch). The original path, kept as a fallback.

    exclusive is accepted but deliberately IGNORED here, for both branches
    -- extraction always targets Sherlock's shared `normal` partition, not
    illorent (see extract_array.sbatch's own header), specifically so
    sessions extract concurrently across the shared pool instead of
    queuing one at a time for a single exclusive node. Honoring
    exclusive=True here would mean each array task grabs a whole
    normal-partition node for itself, undoing that concurrency for no
    benefit (extraction is lightweight fan-out work, not the kind of job
    --exclusive is for). The parameter still exists so submit_master()
    can pass exclusive=... uniformly to every stage without a special
    case; it's just a no-op for this one.

    cores/mem_gb/time, unlike exclusive, ARE honored here (applied per
    array task when use_array=True) -- overriding "how many cores does
    each session's extraction get" is a normal, harmless request, not the
    whole-node problem exclusive would be.
    """
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")

    sessions = sessions_needing_extraction(project_root)
    if not sessions:
        return []

    # exclusive intentionally not passed through -- see this function's
    # docstring on why extraction never honors it, in either branch (both
    # target the `normal` partition, not illorent). cores/mem_gb/time are
    # passed through normally.
    res = _resource_flags("extract", {"n_sessions": len(sessions)}, cores=cores, mem_gb=mem_gb, time=time)

    if not use_array:
        script = EXTRACT_DIR / "extract.sbatch"
        return [
            _sbatch(
                script, project_root, config_file,
                sbatch_flags=_sbatch_flags(project_root, "extract", None) + res,
            )
        ]

    # Write the sessions list so each array task can look up its session by
    # $SLURM_ARRAY_TASK_ID (0-based index into this file).
    status_dir = Path(project_root) / "status"
    status_dir.mkdir(parents=True, exist_ok=True)
    sessions_file = status_dir / "extract_sessions.txt"
    sessions_file.write_text("\n".join(sessions) + "\n")

    log_dir = Path(project_root) / "slurm_logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    # Array log flags use %A (array master job ID) and %a (task index) so
    # each task gets its own file. These override _log_flags' %j format,
    # which would give every task the same filename and cause interleaved writes.
    array_log_flags = [
        f"--output={log_dir}/extract-%A-%a.out",
        f"--error={log_dir}/extract-%A-%a.err",
    ]

    job_id = _sbatch(
        EXTRACT_DIR / "extract_array.sbatch",
        project_root, str(sessions_file), config_file,
        sbatch_flags=[
            *array_log_flags,
            f"--array=0-{len(sessions) - 1}",
            *_dependency_flags(None),
            *_mail_flags(),
            *res,
        ],
    )

    # Validate after all array tasks finish, pass or fail, so the report
    # covers partial failures too (afterany, not afterok).
    _sbatch(
        EXTRACT_DIR / "validate_extractions.sbatch",
        project_root,
        sbatch_flags=_log_flags(project_root, "validate_extractions")
        + [f"--dependency=afterany:{job_id}"]
        + _mail_flags(),
    )

    return [job_id]


def submit_aggregate(
    project_root: str,
    depends_on: list[str] | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
) -> str:
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
        sbatch_flags=_sbatch_flags(project_root, "aggregate", depends_on)
        + _resource_flags("aggregate", exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time),
    )


def submit_pca_fit(
    project_root: str,
    config_file: str | None = None,
    depends_on: list[str] | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
) -> str:
    """Fits PCA across the whole aggregated session batch (see pca_fit.sbatch)."""
    project_root = str(Path(project_root).resolve())
    config_file = config_file or str(Path(project_root) / "config.yaml")
    script = PCA_DIR / "pca_fit.sbatch"
    n = _count_aggregate_sessions(project_root)
    return _sbatch(
        script, project_root, config_file,
        sbatch_flags=_sbatch_flags(project_root, "pca_fit", depends_on)
        + _resource_flags(
            "pca-fit", {"n_sessions": n} if n is not None else {},
            exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
        ),
    )


def submit_pca_apply(
    project_root: str,
    config_file: str | None = None,
    pca_file: str | None = None,
    depends_on: list[str] | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
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
    n = _count_aggregate_sessions(project_root)
    return _sbatch(
        script, project_root, config_file, pca_file,
        sbatch_flags=_sbatch_flags(project_root, "pca_apply", depends_on)
        + _resource_flags(
            "pca-apply", {"n_sessions": n} if n is not None else {},
            exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
        ),
    )


def submit_compute_changepoints(
    project_root: str,
    config_file: str | None = None,
    pca_file_components: str | None = None,
    pca_file_scores: str | None = None,
    depends_on: list[str] | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
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
    n = _count_aggregate_sessions(project_root)
    return _sbatch(
        script,
        project_root,
        config_file,
        pca_file_components,
        pca_file_scores,
        sbatch_flags=_sbatch_flags(project_root, "changepoints", depends_on)
        + _resource_flags(
            "changepoints", {"n_sessions": n} if n is not None else {},
            exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
        ),
    )


def submit_kappa_scan(
    project_root: str,
    n_models: int = 10,
    scan_scale: str = "log",
    min_kappa: float | None = None,
    max_kappa: float | None = None,
    num_iter: int = 100,
    depends_on: list[str] | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
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
        script, *args,
        sbatch_flags=_sbatch_flags(project_root, "kappa_scan", depends_on)
        + _resource_flags(
            "kappa-scan", {"n_models": n_models, "num_iter": num_iter},
            exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
        ),
    )


def submit_learn_model(
    project_root: str,
    kappa: float,
    num_iter: int = 1000,
    dest_name: str = "model.p",
    depends_on: list[str] | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
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
        sbatch_flags=_sbatch_flags(project_root, "learn_model", depends_on)
        + _resource_flags(
            "learn-model", {"num_iter": num_iter},
            exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
        ),
    )


def submit_master(
    project_root: str, config_file: str | None = None, exclusive: bool = False
) -> dict:
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

    exclusive=True applies to every stage in the chain -- intended for a
    genuinely huge/expensive dataset where it's worth reserving the whole
    illorent node for the entire run rather than sharing it stage by
    stage. Note this does NOT affect extraction: that stage always targets
    Sherlock's shared `normal` partition (a fan-out job array, see
    extract_array.sbatch), not illorent, regardless of this flag --
    --exclusive there would reserve a whole normal-partition node PER
    array task, which is not what "give this run all of illorent" means.

    Returns a dict of stage name -> job ID(s) so a caller (CLI or
    notebook) can print/track them, e.g. via `run moseq status` or
    `run moseq logs`.
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
