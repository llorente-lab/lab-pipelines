#!/usr/bin/env python3
"""
Turns a pipeline's resources.yaml into sbatch flags. Shared by moseq's
Python submission code and miniscope's bash CLI, so the estimation logic
only exists once.

From Python:
    from estimate_resources import resource_flags
    flags = resource_flags("pipelines/moseq/resources.yaml", "pca-fit",
                            {"n_sessions": 12}, exclusive=False, cores=None,
                            mem_gb=None, time=None)
    # -> ["--partition=illorent", "--cpus-per-task=8", "--mem=600G"]

From bash (used by cli/resources.sh):
    mapfile -t flags < <(python3 estimate_resources.py \\
        pipelines/moseq/resources.yaml pca-fit n_sessions=12 \\
        --exclusive --cores 8 --mem 200 --time 1-00:00:00)
"""

import math
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    try:
        import ruamel.yaml as yaml
    except ImportError:
        yaml = None


def estimate(resources_yaml, stage, metadata):
    """
    Resource requirements for stage given metadata.

    resources_yaml: path (str or Path) to a pipeline's resources.yaml
    stage: stage name to look up
    metadata: dict of values the stage's formulas can reference

    Returns a dict with keys partition, exclusive, cores, mem_gb -- a
    missing key means "no opinion." `partition` can be a plain string or a
    YAML list (e.g. `[illorent, normal]`); resource_flags() turns a list
    into Slurm's comma-separated --partition=X,Y syntax.
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
    resources_yaml,
    stage,
    metadata=None,
    exclusive=False,
    cores=None,
    mem_gb=None,
    time=None,
):
    """
    Build --partition/--cpus-per-task/--mem/--exclusive/--time sbatch flags
    for one stage, combining the registry's estimate() with explicit
    overrides (which always win). Returns a list of flag strings.

    resources_yaml: path to a pipeline's resources.yaml
    stage: stage name to look up
    metadata: dict of values the stage's formulas can reference
    exclusive: request the whole node -- drops the formula-derived
      cores/mem (those are sized for a typical run, not a whole node)
    cores: explicit --cpus-per-task override (int)
    mem_gb: explicit --mem override in GB (int)
    time: explicit --time override, e.g. "1-00:00:00" (str)
    """
    result = estimate(resources_yaml, stage, metadata or {})

    flags: list[str] = []
    partition = result.get("partition")
    if partition:
        if isinstance(partition, (list, tuple)):
            partition = ",".join(str(p) for p in partition)
        flags.append(f"--partition={partition}")
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


def main():
    """CLI entry point: prints one resolved sbatch flag per line."""
    if len(sys.argv) < 3:
        print(
            "usage: estimate_resources.py <resources.yaml> <stage> [key=value ...] "
            "[--exclusive] [--cores N] [--mem N] [--time T]",
            file=sys.stderr,
        )
        sys.exit(1)
    resources_yaml, stage = sys.argv[1], sys.argv[2]
    metadata = {}
    exclusive = False
    cores = None
    mem_gb = None
    time = None

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
        exclusive=exclusive, cores=cores, mem_gb=mem_gb, time=time,
    ):
        print(flag)


if __name__ == "__main__":
    main()
