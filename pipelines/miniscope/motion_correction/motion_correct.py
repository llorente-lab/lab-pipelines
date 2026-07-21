#!/usr/bin/env python
"""
CaImAn Motion Correction - Sherlock / Apptainer Edition (rewrite)

Runs motion correction + memmap creation + correlation image computation for a
single Miniscope session, then leaves everything in AnalyzedData for the
CNMF-E stage to pick up later.

Directory convention (current, going forward):
    RawData:      {raw_base}/{mouse}/{date}/{tp}/videos/miniscope/*.avi
    AnalyzedData: {analyzed_base}/{mouse}/{date}/{tp}/

Usage:
    python motion_correct.py <mouse> <date> <tp> [--raw-base PATH] [--analyzed-base PATH]

Environment variables (optional):
    MINISCOPE_RAW_BASE      - Base path for RawData (default: $SCRATCH/Miniscope/RawData)
    MINISCOPE_ANALYZED_BASE - Base path for AnalyzedData (default: $SCRATCH/Miniscope/AnalyzedData)

Notes for the Apptainer/Sherlock environment:
    - This script assumes it is being invoked as:
        apptainer exec --env PYTHONNOUSERSITE=1 <sif> python motion_correct.py ...
      PYTHONNOUSERSITE avoids picking up a stray ~/.local site-packages cv2/numpy
      that would otherwise shadow the versions baked into the container.
    - rclone must be reachable inside the container (it is, per the Dockerfile),
      and rclone's config (~/.config/rclone/rclone.conf) must be bind-mounted in,
      since credentials are never baked into the image.
"""

import cv2
import logging
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import os
import psutil
import gc
import time
import json
from PIL import Image
import subprocess
from pathlib import Path
import sys
import argparse

import caiman as cm
from caiman.motion_correction import MotionCorrect
from caiman.source_extraction.cnmf import params as params

# reconcile_common.py lives in ../common relative to this file
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from reconcile_common import gdrive_path

# ---------------------------------------------------------------------------
# Global setup
# ---------------------------------------------------------------------------

# OpenCV threading fights with CaImAn's own multiprocessing cluster, disable it
try:
    cv2.setNumThreads(0)
except Exception:
    pass
cv2.destroyAllWindows = lambda: None  # no-op on a headless node, some caiman code paths call this

logger = logging.getLogger('caiman')
logger.setLevel(logging.DEBUG)
logfmt = logging.Formatter(
    '%(relativeCreated)12d [%(filename)s:%(funcName)20s():%(lineno)s] [%(process)d] %(message)s'
)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logfmt)
logger.addHandler(handler)

FRAME_LIMIT = 36000


# ---------------------------------------------------------------------------
# Path / environment helpers
# ---------------------------------------------------------------------------

def on_sherlock() -> bool:
    return (
        'SLURM_JOB_ID' in os.environ or
        'sherlock' in os.uname().nodename.lower() or
        'sh' in os.uname().nodename.lower()
    )


def get_base_paths():
    """Resolve RawData/AnalyzedData base paths: CLI args > env vars > Sherlock defaults."""
    if on_sherlock():
        scratch = os.environ.get('SCRATCH', f"/scratch/users/{os.environ.get('USER', 'unknown')}")
        default_raw = f"{scratch}/Miniscope/RawData"
        default_analyzed = f"{scratch}/Miniscope/AnalyzedData"
    else:
        default_raw = "/mnt/g/Shared drives/llorente-lab/Miniscope/RawData"
        default_analyzed = "/mnt/h/Miniscope/AnalyzedData"

    raw_base = os.environ.get('MINISCOPE_RAW_BASE', default_raw)
    analyzed_base = os.environ.get('MINISCOPE_ANALYZED_BASE', default_analyzed)
    print(f'Raw data base: {raw_base}')
    print(f'Analyzed data base: {analyzed_base}')
    return raw_base, analyzed_base


def log_memory(tag):
    mem = psutil.virtual_memory()
    print(f"{tag}: used {mem.used / 1e9:.2f} GB, available {mem.available / 1e9:.2f} GB")


def log_step_time(step_name, start_time):
    elapsed = time.time() - start_time
    print(f"TIMING - {step_name}: {elapsed:.2f}s ({elapsed / 60:.2f} min)")
    return elapsed


def construct_movie_path(mouse, date, tp, raw_base):
    """Find the raw video file for this session, preferring a 'trimmed' copy if present."""
    base_dir = Path(raw_base) / mouse / date / tp / "videos" / "miniscope"

    if not base_dir.exists() or not base_dir.is_dir():
        print(f'{base_dir} is not a valid directory.')
        return None

    video_files = [f for f in os.listdir(base_dir) if f.lower().endswith(('.avi', '.mkv'))]
    if not video_files:
        print(f'No video files found in {base_dir}. Files present: {os.listdir(base_dir)}')
        return None

    if len(video_files) > 1:
        print(f'Warning: multiple video files found: {video_files}')
        for v in video_files:
            if 'trimmed' in v.lower():
                print(f"Using trimmed video: {v}")
                return str(base_dir / v)
        print(f"No trimmed file found, using: {video_files[0]}")
        return str(base_dir / video_files[0])

    return str(base_dir / video_files[0])


def run_sync_if_needed(mouse: str, date: str, tp: str, raw_base: Path):
    """
    Pull this session's raw video down from Google Drive into scratch if it isn't
    already there. Unlike the old version, tp is passed in explicitly rather than
    being independently rediscovered from Drive, so the folder this function fills
    in always matches the tp the rest of the script is actually operating on.
    """
    remote_path = gdrive_path("RawData", mouse, date, tp)
    local_path = Path(raw_base) / mouse / date / tp

    print(f"SYNC - Source (remote): {remote_path}")
    print(f"SYNC - Destination (local): {local_path}")

    if local_path.exists():
        video_files = list(local_path.rglob("*.avi")) + list(local_path.rglob("*.mkv"))
        if video_files:
            print(f"SYNC - skipping: found {len(video_files)} video(s) already in {local_path}")
            return
        print("SYNC - directory exists but has no video files, syncing anyway")
    else:
        print("SYNC - local directory missing, syncing now")
        local_path.mkdir(parents=True, exist_ok=True)

    cmd = [
        "rclone", "copy",
        "--progress",
        "--transfers", "8",
        "--checkers", "8",
        "--update",
        "--create-empty-src-dirs",
        remote_path,
        str(local_path),
    ]
    print(f"SYNC - running: {' '.join(cmd)}")

    try:
        subprocess.run(cmd, capture_output=True, text=True, check=True)
        print(f"SYNC - completed for {local_path}")
    except subprocess.CalledProcessError as e:
        print(f"SYNC ERROR - rclone failed with exit code {e.returncode}")
        print(e.stderr.strip())
        return

    synced_videos = list(local_path.rglob("*.avi")) + list(local_path.rglob("*.mkv"))
    if synced_videos:
        print(f"SYNC - found {len(synced_videos)} video(s) after sync")
    else:
        print("SYNC WARNING - no videos found after sync, check remote path")


def get_num_frames(video_path):
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"ERROR - could not open video: {video_path}")
        return None
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    cap.release()
    if total_frames <= 0:
        print(f"WARNING - opencv returned invalid frame count ({total_frames})")
        return None
    return total_frames


def get_fps(video_path):
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate",
        "-of", "default=nokey=1:noprint_wrappers=1",
        video_path,
    ]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    raw_rate = result.stdout.strip()
    if "/" in raw_rate:
        try:
            num, den = map(float, raw_rate.split("/"))
            return num / den if den != 0 else 30.0
        except Exception:
            return 30.0
    try:
        return float(raw_rate)
    except ValueError:
        return 30.0


def trim_video(movie_path, output_path, frame_limit):
    """Trim to frame_limit frames via ffmpeg stream copy (no re-encode), in place if short enough."""
    total_frames = get_num_frames(movie_path)
    if total_frames is None:
        print(f"WARNING - could not determine frame count for {movie_path}, skipping trim")
        return

    if total_frames <= frame_limit:
        print(f"{total_frames} frames is under the {frame_limit} limit, skipping trim")
        return

    fps = get_fps(movie_path)
    print(f"trimming {total_frames} -> {frame_limit} frames (fps={fps:.3f})")

    cmd = [
        "ffmpeg", "-i", movie_path,
        "-frames:v", str(frame_limit),
        "-c:v", "copy",
        "-avoid_negative_ts", "make_zero",
        "-y", output_path,
    ]
    try:
        subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"ERROR - ffmpeg failed:\n{e.stderr}")
        return

    trimmed_frames = get_num_frames(output_path)
    print(f"trimmed video written: {output_path} ({trimmed_frames} frames)")


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def main(mouse, date, tp, raw_base=None, analyzed_base=None, frame_limit=FRAME_LIMIT):
    cluster = None
    timing_log = {}
    total_start = time.time()

    if raw_base is None or analyzed_base is None:
        default_raw, default_analyzed = get_base_paths()
        raw_base = raw_base or default_raw
        analyzed_base = analyzed_base or default_analyzed

    print(f"Processing: {mouse}/{date}/{tp}")
    print(f"RawData base:      {raw_base}")
    print(f"AnalyzedData base: {analyzed_base}")

    try:
        # Step 0: ensure raw video is present locally, syncing from Drive if not
        raw_session_dir = Path(raw_base) / mouse / date / tp
        if not raw_session_dir.exists():
            print(f"WARNING - {raw_session_dir} missing, syncing from Google Drive")
            run_sync_if_needed(mouse, date, tp, Path(raw_base))

        if not raw_session_dir.exists():
            raise FileNotFoundError(f"Raw session directory not found even after sync: {raw_session_dir}")

        # New sessions always write under the tp-level path. (Older sessions that
        # only exist at the mouse/date level are a read-side concern for
        # reconciliation/CNMF-E, not something this script needs to reproduce.)
        data_dir = Path(analyzed_base) / mouse / date / tp
        data_dir.mkdir(parents=True, exist_ok=True)
        print(f"Output directory: {data_dir}")

        # Step 1: locate the movie
        step_start = time.time()
        movie_path = construct_movie_path(mouse, date, tp, raw_base)
        if movie_path is None:
            raise FileNotFoundError(f"Could not find video for {mouse}/{date}/{tp}")
        assert os.path.exists(movie_path), f"Movie file not found: {movie_path}"
        timing_log['construct_path'] = log_step_time("Construct movie path", step_start)

        # Step 2: trim if the recording is unusually long
        step_start = time.time()
        pth = Path(movie_path)
        output_path = pth.with_name(pth.stem + "_trimmed" + pth.suffix)
        trim_video(movie_path, str(output_path), frame_limit)
        if output_path.exists():
            movie_path = str(output_path)
        timing_log['trim_video'] = log_step_time("Trim video", step_start)

        print(f"{psutil.cpu_count()} CPUs available")
        gc.collect()

        # Step 3: start the CaImAn cluster
        step_start = time.time()
        _, cluster, n_processes = cm.cluster.setup_cluster(
            backend='multiprocessing',
            n_processes=None,
            ignore_preexisting=False,
        )
        print(f"Cluster started with {n_processes} processes")
        timing_log['setup_cluster'] = log_step_time("Setup cluster", step_start)

        os.environ['CAIMAN_DATA'] = str(data_dir)
        os.environ['CAIMAN_TEMP'] = str(data_dir)

        frate = 30
        decay_time = 0.5

        # Motion correction parameters (rigid; pw_rigid left off per current lab config)
        mc_dict = {
            'fnames': movie_path,
            'fr': frate,
            'decay_time': decay_time,
            'pw_rigid': False,
            'gSig_filt': (3, 3),
            'max_shifts': (150, 150),
            'strides': (48, 48),
            'overlaps': (24, 24),
            'max_deviation_rigid': 3,
            'border_nan': 'copy',
        }
        mc_params = params.CNMFParams(params_dict=mc_dict)

        log_memory("Start")

        # Step 4: motion correction itself
        step_start = time.time()
        mot_correct = MotionCorrect(movie_path, dview=cluster, **mc_params.get_group('motion'))
        mot_correct.motion_correct(save_movie=True)
        fname_mc = mot_correct.fname_tot_rig

        bord_px = np.ceil(np.max(np.abs(mot_correct.shifts_rig))).astype(int)
        plt.plot(mot_correct.shifts_rig)
        plt.legend(['x shifts', 'y shifts'])
        plt.xlabel('frames')
        plt.ylabel('pixels')
        plt.gcf().set_size_inches(6, 3)
        plt.savefig(data_dir / 'motion_correction_shifts.png')
        plt.close()

        bord_px = 0  # border_nan='copy' means no border to crop
        with open(data_dir / 'bord_px.txt', 'w') as f:
            f.write(f"bord_px: {bord_px}\n")
        timing_log['motion_correction'] = log_step_time("Motion correction", step_start)

        # Step 5: write the memmap CNMF-E will read later. The 'order_c' naming
        # convention here is load-bearing: reconciliation and cnmfe_modeling.py
        # both search for '*.mmap' with 'order_c' in the filename.
        step_start = time.time()
        fname_new = cm.save_memmap(
            fname_mc, base_name='memmap_', order='C',
            border_to_0=bord_px, dview=cluster,
        )
        print(f'mmap saved to {fname_new}')
        timing_log['save_memmap'] = log_step_time("Save memmap", step_start)

        # Step 6: load it back to compute the correlation image
        step_start = time.time()
        Yr, dims, T = cm.load_memmap(fname_new)
        images = Yr.T.reshape((T,) + dims, order='F')
        timing_log['load_memmap'] = log_step_time("Load memmap", step_start)

        step_start = time.time()
        gsig_tmp = (3, 3)
        subsample_factor = max(T // 1000, 1)
        correlation_image, _ = cm.summary_images.correlation_pnr(
            images[::subsample_factor], gSig=gsig_tmp[0], swap_dim=False,
        )
        timing_log['correlation_pnr'] = log_step_time("Correlation/PNR", step_start)

        # Step 7: persist correlation_image.npy. This file is what makes MC-done
        # detectable from Google Drive at all, since the mmap itself never syncs.
        corr_npy_path = data_dir / 'correlation_image.npy'
        np.save(corr_npy_path, correlation_image)
        print(f"Correlation image saved: {corr_npy_path}")

        corr_norm = correlation_image.copy()
        corr_norm = (corr_norm - corr_norm.min()) / (corr_norm.max() - corr_norm.min())
        corr_norm = (corr_norm * 255).astype(np.uint8)
        img_path = data_dir / f'correlation_image_{mouse}_{tp}.png'
        Image.fromarray(corr_norm).save(img_path)

        metadata = {
            'original_shape': correlation_image.shape,
            'original_dtype': str(correlation_image.dtype),
            'original_min': float(correlation_image.min()),
            'original_max': float(correlation_image.max()),
            'note': 'Normalized to 0-255 uint8 for PNG export.',
        }
        with open(data_dir / f'correlation_image_{mouse}_{tp}_metadata.txt', 'w') as f:
            json.dump(metadata, f, indent=2)

        timing_log['total'] = time.time() - total_start
        with open(data_dir / 'timing_log.json', 'w') as f:
            json.dump(timing_log, f, indent=2)

        print(f"Total time: {timing_log['total']:.2f}s ({timing_log['total']/60:.2f} min)")
        return fname_new, correlation_image

    except Exception:
        print("ERROR - motion correction failed")
        import traceback
        traceback.print_exc()
        raise

    finally:
        if cluster is not None:
            try:
                cm.stop_server(dview=cluster)
            except Exception as e:
                print(f"Warning stopping cluster: {e}")
        gc.collect()
        logging.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='CaImAn motion correction for a single session')
    parser.add_argument('mouse', help='Mouse ID (e.g., VK_20250407_a)')
    parser.add_argument('date', help='Date (e.g., 2025-05-10)')
    parser.add_argument('tp', help='Timepoint folder name, exactly matching Google Drive (e.g., tp3-1dpi)')
    parser.add_argument('--raw-base', help='Base path for RawData')
    parser.add_argument('--analyzed-base', help='Base path for AnalyzedData')
    parser.add_argument('--frame-limit', type=int, default=FRAME_LIMIT, help=f'Max frames before trimming (default {FRAME_LIMIT})')

    args = parser.parse_args()

    try:
        main(args.mouse, args.date, args.tp,
             raw_base=args.raw_base, analyzed_base=args.analyzed_base,
             frame_limit=args.frame_limit)
        sys.exit(0)
    except Exception as e:
        print(f"Pipeline failed: {e}")
        sys.exit(1)
