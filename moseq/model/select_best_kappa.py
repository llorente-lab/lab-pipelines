#!/usr/bin/env python
"""
Picks the best-fitting kappa from a completed kappa-scan, using
moseq2-viz's own get_model_kappa_scan_best_fit_wrapper() (which wraps
get_best_fit() in moseq2_viz/model/util.py).

Needs the container (moseq2_viz, and moseq2_model transitively) -- run via
apptainer_python from a job script or manually, not imported by
submit_moseq.py itself (host-side, pure stdlib).

This only PICKS a kappa value and reports/records it -- it does not itself
retrain the final model. Per the lab's stated convention, the kappa scan's
models are deliberately short/exploratory (num_iter ~100-200), so the
selected kappa should be fed into a fresh submit_learn_model() call at a
full iteration count (1000) to produce the actual final model. That final
call is intentionally a separate, explicit step (see submit_moseq.py's
submit_master() docstring for why modeling isn't auto-chained).

Usage:
    apptainer_python select_best_kappa.py <project_root> [--objective ...] [--fps 30]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from moseq2_viz.helpers.wrappers import get_best_fit_model_wrapper

DEFAULT_OBJECTIVE = "median_loglikelihood"  # see UNCONFIRMED note above


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
