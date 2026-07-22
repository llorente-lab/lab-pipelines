#!/usr/bin/env python3
"""
Synthetic-data resource benchmarking harness for pipelines/*/resources.yaml.

Problem this solves: every formula in resources.yaml is currently either
`null` (always fall back to a flat guess) or a placeholder equation nobody
has actually measured against real data. This script generates synthetic
input data at a deliberate sweep of sizes (small -> unrealistically large,
using each pipeline's own tests/generate_*_sample_data.py), runs one real
pipeline stage command per size point, samples peak memory / mean CPU% /
wall time for each run, and fits a simple curve (linear or power-law,
whichever fits better) to suggest a resources.yaml formula -- WITH a safety
margin applied, since a point estimate from a handful of runs should always
be biased toward "don't OOM-kill" rather than "tightest possible fit".

This script never edits resources.yaml itself. It prints a suggested
stanza; a human reviews and pastes it in.

Usage (run on Sherlock, needs apptainer + a built .sif -- see each
pipeline's env_setup.sh):

    # Sweep moseq's extract stage over four session sizes (frame counts),
    # one run per size:
    python3 scripts/benchmark_resources.py \\
        --pipeline moseq --stage extract \\
        --sizes 300,1000,3000,9000

    # Same, but 3 repeats per size point (more robust fit, noisier data
    # averages out):
    python3 scripts/benchmark_resources.py \\
        --pipeline miniscope --stage motion-correction \\
        --sizes 90,300,900,2700 --repeats 3

    # Re-fit from a previous run's CSV without re-executing anything --
    # useful once real production TSVs get folded into the same CSV shape
    # by hand, or to retry a fit with a different margin:
    python3 scripts/benchmark_resources.py \\
        --pipeline moseq --stage extract --fit-only \\
        --results scripts/benchmark_results/moseq_extract.csv --margin 1.5

Adding a new stage to benchmark: add one entry to RECIPES below. A recipe
just needs to know how to generate a synthetic input at a given size and
how to invoke the real stage command against it -- everything else
(sampling, fitting, margin, printing) is generic.
"""

# Needed so the dataclass fields below (which use `int | None` syntax) don't
# get evaluated eagerly -- this repo targets Python 3.9 (see setup.sh), and
# that union syntax only works at runtime on 3.10+.
from __future__ import annotations

import argparse
import csv
import math
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

REPO_ROOT = Path(__file__).resolve().parent.parent

# --- portable resource sampler ------------------------------------------
# Deliberately NOT cgroup-based (unlike common/monitor_resources.sh) --
# this needs to run standalone too (a plain login-node/local test run
# without an active Slurm allocation), not just inside a batch job. Walks
# the actual process tree via `ps` instead, same fallback path
# monitor_resources.sh already uses when cgroups aren't available, so the
# two tools agree on method in the one case they overlap.


def _process_tree_rss_cpu(root_pid):
    """
    Sum RSS and %CPU across root_pid and all its descendants, via a single
    `ps -eo pid,ppid,rss,%cpu` snapshot (cheap, one call covers the whole
    tree instead of walking it recursively).

    root_pid (int): PID of the process tree's root.

    Returns a (float, float) tuple: total RSS in MB, total %CPU.
    """
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid,ppid,rss,pcpu"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return 0.0, 0.0

    rows = []
    for line in out.splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss_kb, cpu = int(parts[0]), int(parts[1]), float(parts[2]), float(parts[3])
        except ValueError:
            continue
        rows.append((pid, ppid, rss_kb, cpu))

    children = {}
    for pid, ppid, _, _ in rows:
        children.setdefault(ppid, []).append(pid)

    keep = set()
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in keep:
            continue
        keep.add(pid)
        stack.extend(children.get(pid, []))

    rss_mb = sum(rss_kb for pid, _, rss_kb, _ in rows if pid in keep) / 1024.0
    cpu_pct = sum(cpu for pid, _, _, cpu in rows if pid in keep)
    return rss_mb, cpu_pct


@dataclass
class SampleResult:
    peak_rss_mb: float = 0.0
    mean_cpu_pct: float = 0.0
    n_samples: int = 0
    wall_s: float = 0.0
    exit_code: int | None = None


def run_and_sample(cmd, interval=2.0, timeout=None):
    """
    Run cmd as a subprocess, polling its full process tree's RSS/CPU every
    `interval` seconds in a background thread until it exits. Returns peak
    RSS (an average would hide the spike that actually matters for sizing
    --mem-per-cpu) and mean CPU% (ps's %cpu is already normalized
    per-core-100%, so this is a reasonable proxy for cores kept busy).

    cmd (list of str): argv to run.
    interval (float): seconds between resource samples.
    timeout (float or None): kill the process if it runs longer than this.

    Returns a SampleResult.
    """
    result = SampleResult()
    cpu_samples = []
    stop = threading.Event()

    t0 = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def _poll():
        while not stop.is_set():
            rss_mb, cpu_pct = _process_tree_rss_cpu(proc.pid)
            if rss_mb > 0:
                result.peak_rss_mb = max(result.peak_rss_mb, rss_mb)
                cpu_samples.append(cpu_pct)
                result.n_samples += 1
            stop.wait(interval)

    poller = threading.Thread(target=_poll, daemon=True)
    poller.start()

    try:
        stdout, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, _ = proc.communicate()
    finally:
        stop.set()
        poller.join(timeout=interval + 5)

    result.wall_s = time.monotonic() - t0
    result.exit_code = proc.returncode
    result.mean_cpu_pct = sum(cpu_samples) / len(cpu_samples) if cpu_samples else 0.0
    if result.exit_code != 0:
        print(f"  [warn] command exited {result.exit_code}, tail of output:", file=sys.stderr)
        print("\n".join((stdout or "").splitlines()[-20:]), file=sys.stderr)
    return result


# --- per-stage recipes ---------------------------------------------------
# A recipe knows: (1) which CLI knob on its generator controls "size", (2)
# how to turn a size value into the metadata columns worth recording
# (usually just n_frames, but left as a dict so a recipe can record more
# than one dimension, e.g. resolution), and (3) how to build the actual
# stage command to benchmark. Two are implemented below as concrete,
# runnable examples -- add more by following the same shape.


@dataclass
class Recipe:
    pipeline: str
    stage: str
    size_metadata_key: str  # column name used as the regressor, e.g. "n_frames"
    setup: Callable[[int, Path], dict]     # (size, workdir) -> extra context dict
    command: Callable[[int, Path, dict], list[str]]  # (size, workdir, ctx) -> argv
    env_setup_relpath: str  # sourced before building the command (for real, non-dry-run use)


def _moseq_extract_setup(size, workdir):
    """
    size (int): number of frames to generate.
    workdir (Path): temp directory to generate synthetic data into.

    Returns a dict with keys project_root and session_dir (both Path).
    """
    gen = REPO_ROOT / "pipelines/moseq/tests/generate_moseq_sample_data.py"
    subprocess.run(
        [sys.executable, str(gen), "--projects-base", str(workdir), "--frames", str(size), "--size", "80"],
        check=True,
    )
    project_root = workdir / "_pipeline_test"
    return {"project_root": project_root, "session_dir": project_root / "session_a"}


def _moseq_extract_command(size, workdir, ctx):
    """
    size (int): unused here, kept for a consistent recipe signature.
    workdir (Path): temp directory holding the synthetic data.
    ctx (dict): return value of _moseq_extract_setup.

    Returns a list of str, the argv to run.
    """
    session_dir = ctx["session_dir"]
    config_file = ctx["project_root"] / "config.yaml"
    # Mirrors extract.sbatch's per-session apptainer_exec call exactly
    # (generate-config once, then plain `extract`, not `batch-extract` --
    # see extract.sbatch's header comment for why).
    return [
        "bash", "-c",
        f'source "{REPO_ROOT}/pipelines/moseq/common/env_setup.sh" >/dev/null 2>&1 && '
        f'[ -f "{config_file}" ] || apptainer_exec moseq2-extract generate-config '
        f'--output-file "{config_file}" --camera-type azure; '
        f'apptainer_exec moseq2-extract extract "{session_dir}/depth.dat" '
        f'--config-file "{config_file}" --output-dir "{session_dir}/proc" '
        f'--cluster-type local --skip-completed',
    ]


def _miniscope_mc_setup(size, workdir):
    """
    size (int): number of frames to generate.
    workdir (Path): temp directory to generate synthetic data into.

    Returns a dict with key raw_base (Path).
    """
    gen = REPO_ROOT / "pipelines/miniscope/tests/generate_sample_data.py"
    subprocess.run(
        [sys.executable, str(gen), "--raw-base", str(workdir), "--frames", str(size), "--size", "100"],
        check=True,
    )
    return {"raw_base": workdir}


def _miniscope_mc_command(size, workdir, ctx):
    """
    Mirrors run_motion_correction's apptainer_python call in
    pipeline_common.sh, run against the single synthetic session directly
    (bypasses reconciliation/mc_queue, same as motion_correction.sbatch's
    <mouse> <date> <tp> direct-session mode).

    size (int): unused here, kept for a consistent recipe signature.
    workdir (Path): unused here, kept for a consistent recipe signature.
    ctx (dict): return value of _miniscope_mc_setup.

    Returns a list of str, the argv to run.
    """
    return [
        "bash", "-c",
        f'source "{REPO_ROOT}/pipelines/miniscope/common/env_setup.sh" >/dev/null 2>&1 && '
        f'MINISCOPE_RAW_BASE="{ctx["raw_base"]}" apptainer_python '
        f'"$CAIMAN_MC_DIR/motion_correct.py" pipeline_test_mouse 2020-01-01 test-session',
    ]


# keys are (pipeline, stage) tuples, values are Recipe instances
RECIPES = {
    ("moseq", "extract"): Recipe(
        pipeline="moseq", stage="extract", size_metadata_key="n_frames",
        setup=_moseq_extract_setup, command=_moseq_extract_command,
        env_setup_relpath="pipelines/moseq/common/env_setup.sh",
    ),
    ("miniscope", "motion-correction"): Recipe(
        pipeline="miniscope", stage="motion-correction", size_metadata_key="n_frames",
        setup=_miniscope_mc_setup, command=_miniscope_mc_command,
        env_setup_relpath="pipelines/miniscope/common/env_setup.sh",
    ),
}


# --- curve fitting ---------------------------------------------------------

def _r_squared(y, y_hat):
    """
    y (list of float): observed values.
    y_hat (list of float): fitted/predicted values.

    Returns a float, the R^2 goodness-of-fit.
    """
    mean_y = sum(y) / len(y)
    ss_tot = sum((v - mean_y) ** 2 for v in y)
    ss_res = sum((v - h) ** 2 for v, h in zip(y, y_hat))
    return 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0


def _linear_fit(x, y):
    """
    Least-squares y = a*x + b.

    x (list of float): regressor values.
    y (list of float): observed values.

    Returns a (float, float, float) tuple: a, b, r_squared.
    """
    n = len(x)
    mean_x, mean_y = sum(x) / n, sum(y) / n
    num = sum((xi - mean_x) * (yi - mean_y) for xi, yi in zip(x, y))
    den = sum((xi - mean_x) ** 2 for xi in x)
    a = num / den if den else 0.0
    b = mean_y - a * mean_x
    y_hat = [a * xi + b for xi in x]
    return a, b, _r_squared(y, y_hat)


def _power_fit(x, y):
    """
    Least-squares y = a * x^p, fit in log-log space. r_squared is computed
    back in the original (not log) space, so it's directly comparable to
    the linear fit's r_squared.

    x (list of float): regressor values.
    y (list of float): observed values.

    Returns a (float, float, float) tuple: a, p, r_squared.
    """
    if any(v <= 0 for v in x) or any(v <= 0 for v in y):
        return 0.0, 1.0, -math.inf  # can't log-transform, disqualify this model
    log_x = [math.log(v) for v in x]
    log_y = [math.log(v) for v in y]
    p, log_a, _ = _linear_fit(log_x, log_y)
    a = math.exp(log_a)
    y_hat = [a * (xi ** p) for xi in x]
    return a, p, _r_squared(y, y_hat)


def suggest_formula(sizes, values, margin, var_name):
    """
    Picks whichever of linear/power-law fits better (by R^2) and returns a
    resources.yaml-ready formula string. `margin` is baked in as a flat
    multiplier applied to the whole formula (not just the fitted slope),
    so it scales the intercept/fallback risk the same way at every input
    size rather than only protecting the high end.

    sizes (list of float): regressor values (the size sweep).
    values (list of float): observed resource values (mem or cores).
    margin (float): safety multiplier.
    var_name (str): variable name to use in the generated formula string.

    Returns a (str, str) tuple: the formula, and a human-readable
    description of which fit was chosen and its R^2.
    """
    a_lin, b_lin, r2_lin = _linear_fit(sizes, values)
    a_pow, p_pow, r2_pow = _power_fit(sizes, values)

    if r2_pow > r2_lin and math.isfinite(r2_pow):
        formula = f"{margin:.2f} * {a_pow:.6g} * {var_name}**{p_pow:.4g}"
        model_desc = f"power-law fit y = {a_pow:.6g} * {var_name}^{p_pow:.4g} (R^2={r2_pow:.3f})"
    else:
        formula = f"{margin:.2f} * ({a_lin:.6g} * {var_name} + {b_lin:.6g})"
        model_desc = f"linear fit y = {a_lin:.6g} * {var_name} + {b_lin:.6g} (R^2={r2_lin:.3f})"
    return formula, model_desc


# --- CSV persistence --------------------------------------------------------

CSV_COLUMNS = ["pipeline", "stage", "size_metadata_key", "size", "peak_rss_mb", "mean_cpu_pct", "wall_s", "exit_code"]


def append_rows(csv_path, rows):
    """
    csv_path (Path): CSV file to append to, created with a header if new.
    rows (list of dict): rows to append, keyed by CSV_COLUMNS.
    """
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not csv_path.exists()
    with open(csv_path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        if write_header:
            w.writeheader()
        for row in rows:
            w.writerow(row)


def read_rows(csv_path):
    """csv_path (Path): CSV file to read. Returns a list of dict."""
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


# --- main ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pipeline", required=True, choices=sorted({p for p, _ in RECIPES}))
    ap.add_argument("--stage", required=True)
    ap.add_argument("--sizes", help="comma-separated size sweep, e.g. 300,1000,3000,9000")
    ap.add_argument("--repeats", type=int, default=1, help="runs per size point (default 1)")
    ap.add_argument("--interval", type=float, default=2.0, help="sampler poll interval, seconds")
    ap.add_argument("--margin", type=float, default=1.3, help="safety multiplier applied to the fitted curve (default 1.3)")
    ap.add_argument("--results", type=Path, default=None, help="CSV to append to / read from (default scripts/benchmark_results/<pipeline>_<stage>.csv)")
    ap.add_argument("--fit-only", action="store_true", help="skip running anything, just fit --results and print a suggestion")
    ap.add_argument("--dry-run", action="store_true", help="print the commands that would run, without executing or generating data")
    ap.add_argument("--keep-workdir", action="store_true", help="don't delete the temp dir holding synthetic data after each run (for inspecting a failure)")
    args = ap.parse_args()

    key = (args.pipeline, args.stage)
    if key not in RECIPES:
        available = ", ".join(f"{p}/{s}" for p, s in RECIPES)
        print(f"error: no recipe for {args.pipeline}/{args.stage}. Available: {available}", file=sys.stderr)
        print("Add one to RECIPES in this file -- see the moseq/extract or miniscope/motion-correction entries as a template.", file=sys.stderr)
        sys.exit(1)
    recipe = RECIPES[key]

    results_path = args.results or (REPO_ROOT / "scripts" / "benchmark_results" / f"{args.pipeline}_{args.stage}.csv")

    if not args.fit_only:
        if not args.sizes:
            print("error: --sizes is required unless --fit-only is set", file=sys.stderr)
            sys.exit(1)
        sizes = [int(s.strip()) for s in args.sizes.split(",") if s.strip()]

        for size in sizes:
            for rep in range(args.repeats):
                print(f"== {args.pipeline}/{args.stage} size={size} (rep {rep + 1}/{args.repeats}) ==")
                workdir = Path(tempfile.mkdtemp(prefix=f"benchmark_{args.pipeline}_{args.stage}_"))
                try:
                    if args.dry_run:
                        print(f"  [dry-run] would generate synthetic data at size={size} under {workdir}")
                        ctx = {"project_root": workdir / "_pipeline_test", "session_dir": workdir / "_pipeline_test/session_a", "raw_base": workdir}
                    else:
                        ctx = recipe.setup(size, workdir)

                    cmd = recipe.command(size, workdir, ctx)
                    print("  cmd:", " ".join(cmd) if len(cmd) < 3 else cmd[-1][:200] + " ...")

                    if args.dry_run:
                        continue

                    sample = run_and_sample(cmd, interval=args.interval)
                    print(f"  peak_rss_mb={sample.peak_rss_mb:.1f} mean_cpu_pct={sample.mean_cpu_pct:.1f} "
                          f"wall_s={sample.wall_s:.1f} exit={sample.exit_code}")
                    append_rows(results_path, [{
                        "pipeline": args.pipeline, "stage": args.stage,
                        "size_metadata_key": recipe.size_metadata_key, "size": size,
                        "peak_rss_mb": f"{sample.peak_rss_mb:.1f}",
                        "mean_cpu_pct": f"{sample.mean_cpu_pct:.1f}",
                        "wall_s": f"{sample.wall_s:.1f}", "exit_code": sample.exit_code,
                    }])
                finally:
                    if not args.keep_workdir:
                        shutil.rmtree(workdir, ignore_errors=True)

        if args.dry_run:
            print(f"\n[dry-run] no data collected, nothing to fit. Results would have been appended to {results_path}")
            return

    if not results_path.exists():
        print(f"error: no results at {results_path} -- run without --fit-only first", file=sys.stderr)
        sys.exit(1)

    rows = [r for r in read_rows(results_path) if r["exit_code"] == "0"]
    if len(rows) < 3:
        print(f"warning: only {len(rows)} successful runs recorded -- a fit from this few points is little more "
              f"than a guess with extra steps. Collect more size points (and/or repeats) before trusting this.", file=sys.stderr)
    if len(rows) < 2:
        print("error: need at least 2 successful data points to fit anything.", file=sys.stderr)
        sys.exit(1)

    sizes = [float(r["size"]) for r in rows]
    mem = [float(r["peak_rss_mb"]) / 1024.0 for r in rows]  # -> GB, matches resources.yaml's mem_gb unit
    # mean_cpu_pct is already normalized per-core = 100%, so /100 converts
    # "sum of %cpu across the tree" into an actual observed core count.
    cores = [float(r["mean_cpu_pct"]) / 100.0 for r in rows]
    wall = [float(r["wall_s"]) for r in rows]

    var = recipe.size_metadata_key
    mem_formula, mem_desc = suggest_formula(sizes, mem, args.margin, var)
    cores_formula, cores_desc = suggest_formula(sizes, cores, args.margin, var)

    print("\n" + "=" * 72)
    print(f"suggested resources.yaml entry for {args.pipeline}/{args.stage}")
    print(f"(from {len(rows)} successful run(s) spanning {var}={min(sizes):.0f}..{max(sizes):.0f}, margin={args.margin}x)")
    print("=" * 72)
    print(f"# mem_gb:   {mem_desc}")
    print(f"# cores:    {cores_desc}")
    print(f"# wall_s observed range: {min(wall):.1f}..{max(wall):.1f} (no formula suggested for --time yet -- ")
    print(f"#           resources.yaml has no wall-time field at all; consider adding one if a stage's")
    print(f"#           cores/mem scale with a variable that also predicts wall time, e.g. num_iter)")
    print()
    print(f"  {args.stage}:")
    print(f"    cores:")
    print(f"      formula: \"{cores_formula}\"")
    print(f"      min: {max(1, math.floor(min(cores) * 0.5))}")
    print(f"      max: {math.ceil(max(cores) * args.margin * 2)}")
    print(f"      fallback: {math.ceil(max(cores) * args.margin)}")
    print(f"    mem_gb:")
    print(f"      formula: \"{mem_formula}\"")
    print(f"      min: {max(1, math.floor(min(mem) * 0.5))}")
    print(f"      max: {math.ceil(max(mem) * args.margin * 2)}")
    print(f"      fallback: {math.ceil(max(mem) * args.margin)}")
    print()
    print("Review before pasting into resources.yaml -- this is a suggestion from a small,")
    print("synthetic sweep, not a substitute for judgment about the actual production data distribution.")


if __name__ == "__main__":
    main()
