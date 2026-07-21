#!/usr/bin/env python3
"""
Resource estimator for pipeline stages.

Reads a pipeline's resources.yaml, evaluates the formula for each resource
dimension with supplied metadata, clamps to [min, max], falls back to the
registry fallback when metadata is missing or formula evaluation fails.

Importable by Python callers:
    from estimate_resources import estimate
    result = estimate("pipelines/moseq/resources.yaml", "pca-fit", {"n_sessions": 12})
    # returns: {"partition": "illorent", "exclusive": False, "cores": 8, "mem_gb": 600, "qos": None}

Also runnable from bash (output is eval-able):
    eval "$(python3 estimate_resources.py pipelines/moseq/resources.yaml pca-fit n_sessions=12)"
    # sets: ESTIMATED_PARTITION, ESTIMATED_CORES, ESTIMATED_MEM_GB, ESTIMATED_EXCLUSIVE, ESTIMATED_QOS

`qos` is a plain passthrough from the registry (no formula, no clamping --
Sherlock's QOS levels are a small fixed set tied to account grants, not
something worth computing). Omit the `qos` key in resources.yaml for any
stage that should just use the cluster's default QOS -- ESTIMATED_QOS is
only set (and only emitted) when a stage explicitly names one, e.g. for a
stage whose --time exceeds the default QOS's MaxWall and genuinely needs a
higher one, not as a blanket priority knob.
"""

from __future__ import annotations
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


def estimate(resources_yaml: str | Path, stage: str, metadata: dict) -> dict:
    """
    Return resource requirements for `stage` given `metadata`.
    Keys: partition, exclusive, cores, mem_gb, qos. Missing key = no opinion
    (qos in particular is only present when the registry names one explicitly).
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
    if stage_cfg.get("qos"):
        result["qos"] = stage_cfg["qos"]
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


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: estimate_resources.py <resources.yaml> <stage> [key=value ...]", file=sys.stderr)
        sys.exit(1)
    resources_yaml, stage = sys.argv[1], sys.argv[2]
    metadata: dict = {}
    for token in sys.argv[3:]:
        if "=" in token:
            k, v = token.split("=", 1)
            try:
                metadata[k] = int(v)
            except ValueError:
                try:
                    metadata[k] = float(v)
                except ValueError:
                    metadata[k] = v
    result = estimate(resources_yaml, stage, metadata)
    if result.get("partition"):
        print(f"ESTIMATED_PARTITION={result['partition']}")
    if result.get("cores") is not None:
        print(f"ESTIMATED_CORES={result['cores']}")
    if result.get("mem_gb") is not None:
        print(f"ESTIMATED_MEM_GB={result['mem_gb']}")
    print(f"ESTIMATED_EXCLUSIVE={'true' if result.get('exclusive') else 'false'}")
    if result.get("qos"):
        print(f"ESTIMATED_QOS={result['qos']}")

if __name__ == "__main__":
    main()
