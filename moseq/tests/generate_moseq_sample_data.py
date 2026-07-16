#!/usr/bin/env python
"""
Builds a tiny synthetic Moseq project so the full pipeline (extract ->
aggregate -> pca-fit -> pca-apply -> changepoints -> kappa-scan) can be
smoke-tested in minutes, without touching any real lab member's data.

Writes a single session with a real depth.dat (raw uint16 frames, the actual
format moseq2-extract expects, not just metadata.json) plus depth_ts.txt and
metadata.json, at:

    {projects_base}/_pipeline_test/session_a/{depth.dat,depth_ts.txt,metadata.json}

Deliberately named _pipeline_test (leading underscore, matches Miniscope's
_pipeline_test sandbox convention) so it's obviously not a real project and
easy to filter out of anything that later lists real projects.

Usage:
    python generate_moseq_sample_data.py [--projects-base PATH] [--frames N] [--size N]
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import numpy as np

TEST_PROJECT = "_pipeline_test"
TEST_SESSION = "session_a"


def default_projects_base() -> str:
    scratch = os.environ.get("GROUP_SCRATCH", f"/scratch/users/{os.environ.get('USER', 'unknown')}")
    return f"{scratch}/Moseq"


def make_depth_recording(session_dir: Path, n_frames: int, size: int):
    """A synthetic depth movie: flat background at 1000mm with a single blob
    (stands in for the animal) that drifts in a slow ellipse. Enough real
    structure for extraction's ROI-finding and PCA to have something
    non-degenerate to work with, unlike a purely uniform frame."""
    rng = np.random.default_rng(0)
    yy, xx = np.mgrid[0:size, 0:size]
    depth = np.full((n_frames, size, size), 1000, dtype=np.uint16)

    for t in range(n_frames):
        cy = size / 2 + size * 0.25 * np.sin(t / 20)
        cx = size / 2 + size * 0.25 * np.cos(t / 25)
        blob = 200 * np.exp(-(((yy - cy) ** 2 + (xx - cx) ** 2) / (2 * (size * 0.15) ** 2)))
        noise = rng.normal(0, 2, size=(size, size))
        depth[t] = np.clip(depth[t].astype(np.float64) - blob + noise, 0, 65535).astype(np.uint16)

    depth.tofile(session_dir / "depth.dat")

    with open(session_dir / "depth_ts.txt", "w") as f:
        for t in range(n_frames):
            f.write(f"{t / 30.0}\n")

    with open(session_dir / "metadata.json", "w") as f:
        json.dump({"SubjectName": "test_subject", "SessionName": TEST_SESSION}, f)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--projects-base", default=None)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--size", type=int, default=80)
    args = parser.parse_args()

    projects_base = args.projects_base or default_projects_base()
    project_dir = Path(projects_base) / TEST_PROJECT
    session_dir = project_dir / TEST_SESSION
    session_dir.mkdir(parents=True, exist_ok=True)

    make_depth_recording(session_dir, args.frames, args.size)

    print(f"wrote synthetic session to {session_dir} ({args.frames} frames, {args.size}x{args.size})")
    print(f"project_root: {project_dir}")


if __name__ == "__main__":
    main()
