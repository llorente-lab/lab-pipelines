#!/usr/bin/env python3
"""
Resource estimator + flag-builder for pipeline stages -- the one place
--exclusive/--cores/--mem/--time -> sbatch-flag logic lives, so it isn't
duplicated between moseq's Python submission code and miniscope's bash CLI.

Importable by Python callers (moseq's submit_moseq.py):
    from estimate_resources import resource_flags
    flags = resource_flags("pipelines/moseq/resources.yaml", "pca-fit",
                            {"n_sessions": 12}, exclusive=False, cores=None,
                            mem_gb=None, time=None)
    # -> ["--partition=illorent", "--cpus-per-task=8", "--mem=600G"]

Also runnable from bash (one flag per line, feed to `mapfile`):
    mapfile -t flags < <(python3 estimate_resources.py \\
        pipelines/moseq/resources.yaml pca-fit n_sessions=12 \\
        --exclusive --cores 8 --mem 200 --time 1-00:00:00)
Used by cli/resources.sh for miniscope's sbatch calls.

A stage whose registry entry sets `gpus` gets --partition=<gpu_partition>
--gpus=N automatically; pass --no-gpu (or gpu=False in Python) to force
that stage onto its plain CPU partition instead, with a warning.
"""

from __future__ import annotations
import math
import sys
from pathlib import Path

# Sherlock's shared GPU partition, open to anyone with a Sherlock account
# (not illorent-specific) -- see https://www.sherlock.stanford.edu docs'
# "GPU nodes" section. GPU jobs there are requested with --gpus/-G, not
# --gres=gpu:N.
SHERLOCK_GPU_PARTITION = "gpu"

try:
    import yaml
except ImportError:
    try:
        import ruamel.yaml as yaml
    except ImportError:
        yaml = None


def estimate(resources_yaml: str | Path, stage: str, metadata: dict) -> dict:
    """
    Return resource requirements for `stage` given `metadata`.
    Keys: partition, exclusive, cores, mem_gb, gpus, gpu_partition.
    Missing key = no opinion.

    gpus is a plain passthrough count (Sherlock's GPU accounting is a fixed
    device count per job, not something worth estimating from dataset
    size), requested via --gpus on gpu_partition (defaults to Sherlock's
    shared `gpu` partition, open to anyone -- see SHERLOCK_GPU_PARTITION).
    Stages that don't need a GPU just omit `gpus` entirely.
    """
    if yaml is None:
        return {}
    path = Path(resources_yaml)
    if not path.exists():
        return {}
    with open(path) as f:
        if hasattr(yaml, "safe_load"):
            registry = yaml.safe_load(f)
        else:
            registry = yaml.YAML().load(f)
    stage_cfg = (registry or {}).get("stages", {}).get(stage)
    if not stage_cfg:
        return {}

    result: dict = {
        "partition": stage_cfg.get("partition", "illorent"),
        "exclusive": bool(stage_cfg.get("exclusive", False)),
    }
    if stage_cfg.get("gpus"):
        result["gpus"] = int(stage_cfg["gpus"])
        result["gpu_partition"] = stage_cfg.get("gpu_partition", SHERLOCK_GPU_PARTITION)
    _ns = {"math": math, "min": min, "max": max, "int": int, **metadata}
    for resource in ("cores", "mem_gb"):
        cfg = stage_cfg.get(resource) or {}
        formula = cfg.get("formula")
        minimum = cfg.get("min", 1)
        maximum = cfg.get("max")
        fallback = cfg.get("fallback")
        value = None
        if formula and metadata:
            try:
                raw = eval(formula, {"__builtins__": {}}, _ns)  # noqa: S307
                value = int(math.ceil(float(raw)))
                value = max(minimum, value)
                if maximum is not None:
                    value = min(maximum, value)
            except Exception:
                value = None
        if value is None:
            value = fallback
        if value is not None:
            result[resource] = int(value)
    return result


def resource_flags(
    resources_yaml: str | Path,
    stage: str,
    metadata: dict | None = None,
    exclusive: bool = False,
    cores: int | None = None,
    mem_gb: int | None = None,
    time: str | None = None,
    gpu: bool = True,
) -> list[str]:
    """
    Compute --partition/--cpus-per-task/--mem/--exclusive/--gpus/--time
    sbatch flags for one stage. Combines the registry's estimate() with
    explicit overrides -- the single implementation both moseq (calls this
    directly) and miniscope (calls it via this module's CLI, see
    cli/resources.sh) use.

    exclusive=True drops the formula-derived --cpus-per-task/--mem (those
    are calibrated for a typical run, not a whole-node request) and adds
    --exclusive instead. cores/mem_gb/time are explicit per-invocation
    overrides that always win, even combined with exclusive=True.

    gpu=True (default): if the registry wants a GPU for this stage
    (`gpus` set), honor it -- overrides `partition` with `gpu_partition`
    and adds --gpus=N. gpu=False forces the stage's plain CPU partition/
    cores/mem instead, even if the registry wants a GPU, and prints a
    warning to stderr -- an explicit, visible fallback (e.g. for testing
    without GPU queue access, or if the gpu partition is backed up) rather
    than a silent one.
    """
    result = estimate(resources_yaml, stage, metadata or {})

    flags: list[str] = []
    wants_gpu = gpu and result.get("gpus")
    if not gpu and result.get("gpus"):
        print(
            f"warning: stage '{stage}' normally requests a GPU "
            f"(--gpus={result['gpus']} on partition '{result.get('gpu_partition')}'); "
            f"running on CPU only ('{result.get('partition')}') instead -- expect it to be slower.",
            file=sys.stderr,
        )

    if wants_gpu:
        flags.append(f"--partition={result['gpu_partition']}")
        flags.append(f"--gpus={result['gpus']}")
    elif result.get("partition"):
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


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "usage: estimate_resources.py <resources.yaml> <stage> [key=value ...] "
            "[--exclusive] [--cores N] [--mem N] [--time T] [--no-gpu]",
            file=sys.stderr,
        )
        sys.exit(1)
    resources_yaml, stage = sys.argv[1], sys.argv[2]
    metadata: dict = {}
    exclusive = False
    cores: int | None = None
    mem_gb: int | None = None
    time: str | None = None
    gpu = True

    args = sys.argv[3:]
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--exclusive":
            exclusive = True
            i += 1
        elif tok == "--cores":
            cores = int(args[i + 1])
            i += 2
        elif tok == "--mem":
            mem_gb = int(args[i + 1])
            i += 2
        elif tok == "--time":
            time = args[i + 1]
            i += 2
        elif tok == "--no-gpu":
            gpu = False
            i += 1
        elif "=" in tok:
            k, v = tok.split("=", 1)
            try:
                metadata[k] = int(v)
            except ValueError:
                try:
                    metadata[k] = float(v)
                except ValueError:
                    metadata[k] = v
            i += 1
        else:
            i += 1

    for flag in resource_flags(
        resources_yaml, stage, metadata,
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time, gpu=gpu,
    ):
        print(flag)


if __name__ == "__main__":
    main()
