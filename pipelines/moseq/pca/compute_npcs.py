#!/usr/bin/env python
"""
Reads _pca/pca.h5's explained_variance_ratio and computes the smallest
number of PCs whose cumulative explained variance reaches a target
threshold (default 90%), then writes that back into config.yaml's `npcs`
field so downstream steps (and a human skimming config.yaml) can see what
was auto-selected.

Needs h5py/numpy, which live in the container -- run via apptainer_python,
not imported by submit_moseq.py itself (host-side, pure stdlib). Called
automatically at the end of pca_fit.sbatch, right after train-pca succeeds.

Auto-selecting here doesn't replace human review -- per the earlier design
discussion, this just removes the "eyeball the scree plot" hard gate,
`_pca/pca_scree.png` (moseq2-pca's own output) is still there to check/
override this value manually if it looks wrong.

Usage:
    apptainer_python compute_npcs.py <project_root> [--threshold 90]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

# h5py and ruamel.yaml are deliberately NOT imported at module level -- only
# available inside the container. Importing them lazily, inside the two
# functions that actually need them, keeps npcs_for_variance() (the one
# piece of real selection logic, most likely to hide an off-by-one bug)
# importable and unit-testable on a bare host with just numpy, no container
# needed. See moseq/tests/test_compute_npcs.py.


def npcs_for_variance(explained_variance_ratio, threshold: float = 90.0) -> int:
    """
    Smallest n such that the cumulative explained variance of the first n
    PCs is >= threshold percent. Mirrors the logic in moseq2_pca/viz.py's
    scree_plot(), not exposed there as a standalone function, so
    reimplemented here directly. Pure numpy, no file I/O -- takes the
    explained_variance_ratio array directly so it's testable without a
    real pca.h5/the container. Falls back to using every available PC if
    the threshold is never reached (shouldn't normally happen with a sane
    --rank).
    """
    explained_variance_ratio = np.asarray(explained_variance_ratio)
    cumulative_pct = np.cumsum(explained_variance_ratio) * 100
    hits = np.where(cumulative_pct >= threshold)[0]
    if len(hits) == 0:
        return len(explained_variance_ratio)
    return int(hits[0]) + 1  # 1-indexed: index 0 means "the first PC alone" -> npcs=1


def compute_npcs(pca_h5_path: str, threshold: float = 90.0) -> int:
    """
    Reads explained_variance_ratio out of pca.h5 (written by
    train_pca_wrapper) and delegates to npcs_for_variance() for the actual
    selection math.
    """
    import h5py

    with h5py.File(pca_h5_path, "r") as f:
        explained_variance_ratio = f["explained_variance_ratio"][()]
    return npcs_for_variance(explained_variance_ratio, threshold)


def update_config_npcs(config_path: str, npcs: int) -> None:
    """
    Uses ruamel.yaml (round-trip mode preserves comments/formatting/key
    order in config.yaml) rather than plain PyYAML, matching how moseq2's
    own CLI reads/writes config.yaml elsewhere.
    """
    import ruamel.yaml as yaml

    y = yaml.YAML()
    y.preserve_quotes = True
    with open(config_path) as f:
        config = y.load(f)
    config["npcs"] = npcs
    with open(config_path, "w") as f:
        y.dump(config, f)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_root")
    parser.add_argument(
        "--threshold", type=float, default=90.0,
        help="Cumulative explained variance percentage target (default 90)",
    )
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    pca_h5 = project_root / "_pca" / "pca.h5"
    config_path = project_root / "config.yaml"

    if not pca_h5.exists():
        print(f"compute_npcs.py: {pca_h5} not found -- did train-pca actually succeed?", file=sys.stderr)
        sys.exit(1)

    npcs = compute_npcs(str(pca_h5), args.threshold)
    print(f"npcs explaining >= {args.threshold}% variance: {npcs}")

    if config_path.exists():
        update_config_npcs(str(config_path), npcs)
        print(f"updated {config_path}: npcs = {npcs}")
    else:
        print(f"compute_npcs.py: {config_path} not found, npcs not persisted anywhere", file=sys.stderr)


if __name__ == "__main__":
    main()
