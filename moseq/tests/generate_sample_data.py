#!/usr/bin/env python
"""
Builds a tiny synthetic Moseq session so the full pipeline (extract ->
aggregate -> PCA fit/apply -> changepoints -> kappa-scan) can run end to end
in minutes instead of hours, without touching any real animal's data.

Writes depth.dat (raw uint16 frames, moseq2-extract's expected format) +
depth_ts.txt (per-frame timestamps) + metadata.json at:

    {project_root}/{TEST_SESSION}/depth.dat
    {project_root}/{TEST_SESSION}/depth_ts.txt
    {project_root}/{TEST_SESSION}/metadata.json

Same idea as miniscope/tests/generate_sample_data.py: a moving blob against
a flat background gives extraction/PCA something real to chew on, without
needing an actual depth camera recording. TEST_SESSION is deliberately
inside a dedicated _pipeline_test project directory (see test_full_pipeline.sh),
never a real lab member's project.

Usage:
    python generate_sample_data.py <project_root> [--frames N] [--size N]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

TEST_SESSION = "session_a"


def make_depth_recording(n_frames: int, size: int) -> np.ndarray:
    """
    Flat background at 1000 (mm-ish units) with one Gaussian blob (stands in
    for an animal's back) drifting in a small circle and breathing
    (amplitude oscillation) -- enough structure for PCA to find real
    variance to explain, unlike pure noise.
    """
    rng = np.random.default_rng(0)
    depth = np.full((n_frames, size, size), 1000, dtype=np.uint16)
    yy, xx = np.mgrid[0:size, 0:size]

    cx0, cy0 = size / 2, size / 2
    radius = size * 0.15
    for t in range(n_frames):
        cx = cx0 + radius * np.cos(t / 20)
        cy = cy0 + radius * np.sin(t / 20)
        amp = 150 + 30 * np.sin(t / 6)  # "breathing"
        blob = amp * np.exp(-(((yy - cy) ** 2 + (xx - cx) ** 2) / (2 * (size * 0.12) ** 2)))
        depth[t] -= blob.astype(np.uint16)

    return depth


def write_session(project_root: str, n_frames: int, size: int) -> Path:
    session_dir = Path(project_root) / TEST_SESSION
    session_dir.mkdir(parents=True, exist_ok=True)

    depth = make_depth_recording(n_frames, size)
    depth.tofile(session_dir / "depth.dat")

    fps = 30.0
    with open(session_dir / "depth_ts.txt", "w") as f:
        for t in range(n_frames):
            f.write(f"{t / fps}\n")

    metadata = {"SubjectName": "test_subject", "SessionName": TEST_SESSION}
    with open(session_dir / "metadata.json", "w") as f:
        json.dump(metadata, f)

    return session_dir


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_root")
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--size", type=int, default=80)
    args = parser.parse_args()

    session_dir = write_session(args.project_root, args.frames, args.size)
    print(f"wrote synthetic session to {session_dir} ({args.frames} frames, {args.size}x{args.size})")
    print(f"session name: {TEST_SESSION}")


if __name__ == "__main__":
    main()
