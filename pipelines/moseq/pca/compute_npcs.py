#!/usr/bin/env python
"""Auto-select npcs from pca.h5 explained variance and write back to config.yaml.

Usage:
    apptainer_python compute_npcs.py <project_root> [--threshold 90]
"""

import argparse
import sys
from pathlib import Path
import ruamel.yaml as yaml

import numpy as np

# h5py and ruamel.yaml are lazy imports: only available inside the container,
# and keeping them out of module scope lets npcs_for_variance() be unit-tested
# on a bare host with just numpy.


def npcs_for_variance(explained_variance_ratio, threshold=90.0):
    """
    Smallest n such that the first n PCs explain >= threshold% cumulative
    variance.

    explained_variance_ratio (array-like of float): per-PC explained
        variance ratio, as stored in pca.h5.
    threshold (float): target cumulative explained variance percentage.

    Returns an int, the number of PCs needed.
    """
    explained_variance_ratio = np.asarray(explained_variance_ratio)
    cumulative_pct = np.cumsum(explained_variance_ratio) * 100
    idxs = np.where(cumulative_pct >= threshold)[0]
    if len(idxs) == 0:
        return len(explained_variance_ratio)
    return int(idxs[0]) + 1  # index 0 == first PC alone, so +1 converts to count


def compute_npcs(pca_h5_path, threshold=90.0):
    """
    Read explained_variance_ratio from pca.h5 and delegate to
    npcs_for_variance().

    pca_h5_path (str): path to the pca.h5 file.
    threshold (float): target cumulative explained variance percentage.

    Returns an int, the number of PCs needed.
    """
    import h5py

    with h5py.File(pca_h5_path, "r") as f:
        explained_variance_ratio = f["explained_variance_ratio"][()]
    return npcs_for_variance(explained_variance_ratio, threshold)


def update_config_npcs(config_path, npcs):
    """
    Write npcs into config.yaml using ruamel.yaml round-trip mode to
    preserve formatting.

    config_path (str): path to the project's config.yaml.
    npcs (int): number of PCs to write into the config.
    """

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
