#!/usr/bin/env python
"""
Builds a tiny synthetic RawData session so motion_correct.py can run end to
end in seconds instead of hours, without touching any real mouse's data.

Writes a short, low-resolution .avi with a few moving Gaussian blobs (stands
in for cells) at:

    {raw_base}/{TEST_MOUSE}/{TEST_DATE}/{TEST_TP}/videos/miniscope/sample.avi

TEST_MOUSE deliberately does NOT start with "VK_", so real reconciliation
(which filters on that prefix) can never pick this session up even if it
somehow ended up under a real RawData tree. It won't: this script only
writes to $SCRATCH, never to Drive.

Usage:
    python generate_sample_data.py [--raw-base PATH] [--frames N] [--size N]
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import numpy as np
import cv2

TEST_MOUSE = "pipeline_test_mouse"
TEST_DATE = "2020-01-01"
TEST_TP = "test-session"


def default_raw_base() -> str:
    scratch = os.environ.get("SCRATCH", f"/scratch/users/{os.environ.get('USER', 'unknown')}")
    return f"{scratch}/Miniscope/RawData"


def make_video(out_path: Path, n_frames: int, size: int):
    """A synthetic movie: dim noise background plus a handful of blobs that
    drift and blink
    """
    rng = np.random.default_rng(0)
    fourcc = cv2.VideoWriter_fourcc(*"MJPG")
    writer = cv2.VideoWriter(str(out_path), fourcc, 30, (size, size), isColor=False)

    n_blobs = 5
    centers = rng.uniform(size * 0.2, size * 0.8, size=(n_blobs, 2))
    yy, xx = np.mgrid[0:size, 0:size]

    for t in range(n_frames):
        frame = rng.normal(loc=20, scale=3, size=(size, size))
        drift = np.array([np.sin(t / 15) * 2, np.cos(t / 20) * 2])
        for i in range(n_blobs):
            cy, cx = centers[i] + drift
            amp = 80 + 40 * np.sin(t / 5 + i)
            frame += amp * np.exp(-(((yy - cy) ** 2 + (xx - cx) ** 2) / (2 * 4 ** 2)))
        frame = np.clip(frame, 0, 255).astype(np.uint8)
        writer.write(frame)

    writer.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-base", default=None)
    parser.add_argument("--frames", type=int, default=90)
    parser.add_argument("--size", type=int, default=100)
    args = parser.parse_args()

    raw_base = args.raw_base or default_raw_base()
    session_dir = Path(raw_base) / TEST_MOUSE / TEST_DATE / TEST_TP / "videos" / "miniscope"
    session_dir.mkdir(parents=True, exist_ok=True)

    out_path = session_dir / "sample.avi"
    make_video(out_path, args.frames, args.size)

    print(f"wrote {out_path} ({args.frames} frames, {args.size}x{args.size})")
    print(f"session: {TEST_MOUSE}/{TEST_DATE}/{TEST_TP}")
    print(f"raw_base used: {raw_base}")


if __name__ == "__main__":
    main()
