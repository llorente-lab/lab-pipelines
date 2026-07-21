#!/usr/bin/env python
"""Pick the best-fitting kappa from a completed kappa-scan via moseq2-viz.

Usage:
    apptainer_python select_best_kappa.py <project_root> [--objective ...] [--fps 30]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from moseq2_viz.helpers.wrappers import get_best_fit_model_wrapper

DEFAULT_OBJECTIVE = "median_loglikelihood"


def select_best_kappa(project_root: str, objective: str = DEFAULT_OBJECTIVE, fps: int = 30) -> dict:
    project_root_path = Path(project_root).resolve()
    model_dir = project_root_path / "models"
    cp_file = project_root_path / "_pca" / "changepoints.h5"
    output_file = model_dir / "kappa_scan_plot.png"

    if not cp_file.exists():
        raise FileNotFoundError(
            f"{cp_file} not found -- compute-changepoints must run before kappa "
            f"selection (get_best_fit() compares scanned models against it)."
        )

    best_model_info, _fig = get_best_fit_model_wrapper(
        model_dir=str(model_dir),
        cp_file=str(cp_file),
        output_file=str(output_file),
        objective=objective,
        fps=fps,
        ext=".p",
    )
    return best_model_info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_root")
    parser.add_argument("--objective", default=DEFAULT_OBJECTIVE)
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()

    best_model_info = select_best_kappa(args.project_root, args.objective, args.fps)

    print("kappa-scan best-fit results (objective:", args.objective, "):")
    for key, value in best_model_info.items():
        print(f"  {key}: {value}")

    result_path = Path(args.project_root).resolve() / "models" / "best_kappa_selection.json"
    with open(result_path, "w") as f:
        json.dump({k: str(v) for k, v in best_model_info.items()}, f, indent=2)
    print(f"wrote {result_path}")


if __name__ == "__main__":
    main()
