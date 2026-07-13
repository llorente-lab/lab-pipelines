#!/usr/bin/env python
"""
CNMF-E Modeling - Sherlock / Apptainer Edition (rewrite)

Seeded CNMF-E using manual ROI masks for Miniscope data.

Requires, per session:
    - Motion-corrected mmap file (*.mmap with 'order_c' in name)
    - ROI file (*.zip from ImageJ/FIJI)
    - Correlation image (correlation_image.npy)

Directory resolution:
    Tries {analyzed_base}/{mouse}/{date}/{tp}/ first (current convention),
    then falls back to {analyzed_base}/{mouse}/{date}/ (older sessions that
    predate the tp-level directory convention). Whichever of the two actually
    contains all three required files wins; if neither does, this fails with
    a clear error naming both paths it checked.

Usage:
    python cnmfe_modeling.py <mouse> <date> <tp> --analyzed-base <path>

Environment variables (optional):
    MINISCOPE_ANALYZED_BASE - Base path for AnalyzedData

Notes for the Apptainer/Sherlock environment:
    Run as: apptainer exec --env PYTHONNOUSERSITE=1 <sif> python cnmfe_modeling.py ...
    (see motion_correct.py for why PYTHONNOUSERSITE matters here)
"""

import roifile
import cv2
import logging
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import os
from pathlib import Path
import psutil
import sys
import gc
import time
import joblib
import argparse
import scipy.sparse as sp
from scipy.ndimage import binary_fill_holes, binary_dilation
from skimage.draw import polygon

import caiman as cm
from caiman.source_extraction import cnmf
from caiman.source_extraction.cnmf import params as params
from caiman.utils.visualization import plot_contours

try:
    cv2.setNumThreads(0)
    cv2.destroyAllWindows = lambda: None
except Exception:
    pass

# CNMF-E dataset-level parameters
FRATE = 30
DECAY_TIME = 0.5

logger = logging.getLogger('caiman')
logger.setLevel(logging.DEBUG)
logfmt = logging.Formatter(
    '%(relativeCreated)12d [%(filename)s:%(funcName)20s():%(lineno)s] [%(process)d] %(message)s'
)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logfmt)
logger.addHandler(handler)

print(f"{psutil.cpu_count()} CPUs available")


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

def on_sherlock() -> bool:
    return (
        'SLURM_JOB_ID' in os.environ or
        'sherlock' in os.uname().nodename.lower() or
        'sh' in os.uname().nodename.lower()
    )


def get_analyzed_base():
    if on_sherlock():
        scratch = os.environ.get('SCRATCH', f"/scratch/users/{os.environ.get('USER', 'unknown')}")
        default_analyzed = f"{scratch}/Miniscope/AnalyzedData"
    else:
        default_analyzed = "H:/Shared drives/llorente-lab/Miniscope/AnalyzedData"
    return os.environ.get('MINISCOPE_ANALYZED_BASE', default_analyzed)


def check_required_files(candidate_path: Path) -> dict:
    """
    Check whether candidate_path contains all three files CNMF-E needs.
    Returns a dict of found paths (possibly incomplete), never raises.
    """
    if not candidate_path.exists():
        return {}

    all_files = list(candidate_path.rglob('*'))

    mmap_files = [f for f in all_files if f.suffix == '.mmap' and 'order_c' in f.name.lower()]
    roi_files = [f for f in all_files if f.suffix == '.zip']
    corr_files = [f for f in all_files if 'correlation_image' in f.name.lower() and f.suffix == '.npy']

    found = {}
    if mmap_files:
        found['mmap'] = mmap_files[0]
    if roi_files:
        found['roi'] = roi_files[0]
    if corr_files:
        found['correlation'] = corr_files[0]
    return found


def resolve_analyzed_path(analyzed_base: str, mouse: str, date: str, tp: str) -> tuple[Path, dict]:
    """
    Find the AnalyzedData directory that actually has everything CNMF-E needs.

    Tries mouse/date/tp first (current convention), then mouse/date (older
    sessions predating the tp-level layout). Raises FileNotFoundError with a
    message naming both candidate paths and exactly what was missing at each,
    if neither is complete.
    """
    candidates = [
        Path(analyzed_base) / mouse / date / tp,
        Path(analyzed_base) / mouse / date,
    ]

    required = {'mmap', 'roi', 'correlation'}
    attempts = []

    for candidate in candidates:
        found = check_required_files(candidate)
        missing = required - found.keys()
        attempts.append((candidate, missing))
        if not missing:
            print(f"Using AnalyzedData path: {candidate}")
            for key, path in found.items():
                print(f"  found {key}: {path.name}")
            return candidate, found

    # Neither candidate had everything: build a precise error message
    lines = ["Unable to find all required files for CNMF-E at either candidate path:"]
    for candidate, missing in attempts:
        exists = "exists" if candidate.exists() else "does not exist"
        missing_str = ", ".join(sorted(missing)) if missing else "none"
        lines.append(f"  {candidate} ({exists}) -- missing: {missing_str}")
    raise FileNotFoundError("\n".join(lines))


def load_roi_masks(roi_path: Path, dims: tuple) -> sp.csc_matrix:
    """Load ROI masks from an ImageJ/FIJI .zip file and convert to a sparse initial-components matrix."""
    print(f"\nLoading ROI masks from {roi_path}")
    rois = roifile.ImagejRoi.fromfile(roi_path)
    if not isinstance(rois, list):
        rois = [rois]
    print(f"Found {len(rois)} ROIs")

    masks = []
    for i, roi in enumerate(rois):
        mask = np.zeros(dims, dtype=bool)
        if hasattr(roi, 'coordinates'):
            coords = roi.coordinates()
            if coords is not None and len(coords) > 0:
                rr, cc = polygon(coords[:, 1], coords[:, 0], shape=dims)
                mask[rr, cc] = True
                mask = binary_fill_holes(mask)
                mask = binary_dilation(mask, iterations=1)
                masks.append(mask)
                print(f"  ROI {i + 1}: {np.sum(mask)} pixels")

    if not masks:
        raise ValueError("No valid ROI masks could be extracted from the ROI zip")

    n_pixels = dims[0] * dims[1]
    n_components = len(masks)
    A_init = sp.lil_matrix((n_pixels, n_components), dtype=np.float32)
    for i, mask in enumerate(masks):
        flat_mask = mask.flatten('F')  # Fortran order, matches CaImAn's own convention
        A_init[flat_mask, i] = 1.0
    A_init = A_init.tocsc()

    print(f"Initial spatial components matrix: {A_init.shape} ({n_components} components, {n_pixels} pixels)")
    return A_init


def start_cluster():
    gc.collect()
    os.environ["MKL_NUM_THREADS"] = "1"
    os.environ["OPENBLAS_NUM_THREADS"] = "1"
    os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
    _, cluster, n_processes = cm.cluster.setup_cluster(
        backend='multiprocessing', n_processes=None, ignore_preexisting=False,
    )
    print(f"Cluster started with {n_processes} processes")
    return cluster, n_processes


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def run_cnmfe(mouse: str, date: str, tp: str, analyzed_base: str):
    cluster = None
    try:
        print(f"\nCNMF-E analysis")
        print(f"mouse: {mouse}, date: {date}, tp: {tp}")

        analyzed_path, files = resolve_analyzed_path(analyzed_base, mouse, date, tp)

        cluster, n_processes = start_cluster()

        print(f"\nLoading mmap file: {files['mmap'].name}")
        Yr, dims, T = cm.load_memmap(str(files['mmap']))
        images = Yr.T.reshape((T,) + dims, order='F')
        print(f"Loaded: dims={dims}, frames={T}")

        print(f"\nLoading correlation image: {files['correlation'].name}")
        Cn = np.load(str(files['correlation']))
        print(f"Correlation image shape: {Cn.shape}")

        A_init = load_roi_masks(files['roi'], dims)

        opts_dict = {
            'fnames': [str(files['mmap'])],
            'fr': FRATE,
            'decay_time': DECAY_TIME,
            'method_init': 'greedy_roi',  # seeded initialization from manual ROIs
            'K': A_init.shape[1],
            'gSig': (3, 3),
            'gSiz': (7, 7),
            'merge_thr': 0.7,
            'p': 1,
            'tsub': 2,
            'ssub': 1,
            'rf': 20,
            'stride': 10,
            'only_init': True,
            'nb': 0,
            'nb_patch': 0,
            'method_deconvolution': 'oasis',
            'low_rank_background': None,
            'update_background_components': True,
            'min_corr': 0.8,
            'min_pnr': 10,
            'normalize_init': False,
            'center_psf': True,
            'ssub_B': 2,
            'ring_size_factor': 1.4,
            'del_duplicates': True,
            'border_pix': 0,
        }
        opts = params.CNMFParams(params_dict=opts_dict)

        print("\nInitializing CNMF-E model with manual ROIs...")
        cnm_model = cnmf.CNMF(n_processes=n_processes, dview=cluster, Ain=A_init, params=opts)

        print("\nFitting CNMF-E model (this may take a while)...")
        fit_start = time.time()
        cnm_model = cnm_model.fit(images)
        fit_time = time.time() - fit_start
        print(f"Fit complete in {fit_time:.1f}s, found {cnm_model.estimates.A.shape[1]} components")

        cnm_model.estimates.Cn = Cn

        # Outputs are always written under the resolved analyzed_path, i.e. wherever
        # the input files actually were, whether that's the tp-level or mouse/date-
        # level directory. This keeps results colocated with their inputs rather
        # than assuming a fixed depth.
        joblib_path = analyzed_path / f'cnmfe_model_seeded_{mouse}_{date}_{tp}.joblib'
        joblib.dump(cnm_model, str(joblib_path))
        print(f"Saved model: {joblib_path.name}")

        hdf5_path = analyzed_path / f'cnmfe_results_{mouse}_{date}_{tp}.hdf5'
        cnm_model.save(str(hdf5_path))
        print(f"Saved HDF5: {hdf5_path.name}")

        traces_csv = analyzed_path / f'cnmfe_traces_{mouse}_{date}_{tp}.csv'
        np.savetxt(str(traces_csv), cnm_model.estimates.C, delimiter=',')
        print(f"Saved traces: {traces_csv.name}")

        fig, ax = plt.subplots(figsize=(12, 10))
        ax.imshow(Cn, cmap='gray')
        plot_contours(cnm_model.estimates.A, Cn, thr=0.9, display_numbers=True, cmap='viridis')
        plt.title(f'CNMF-E Components - {mouse} {date} {tp}')
        plt.tight_layout()
        contour_path = analyzed_path / f'cnmfe_contours_{mouse}_{date}_{tp}.png'
        plt.savefig(str(contour_path), dpi=150)
        plt.close()
        print(f"Saved contour plot: {contour_path.name}")

        print(f"\nCNMF-E analysis complete, total components: {cnm_model.estimates.A.shape[1]}, results: {analyzed_path}")
        return cnm_model

    except Exception:
        print("\nERROR - CNMF-E analysis failed")
        import traceback
        traceback.print_exc()
        raise

    finally:
        if cluster is not None:
            try:
                cm.stop_server(dview=cluster)
            except Exception as e:
                print(f"Warning stopping cluster: {e}")
            finally:
                cluster = None
                gc.collect()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description='CNMF-E modeling for Miniscope data',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python cnmfe_modeling.py VK_20250407_a 2025-05-10 tp3-1dpi
  python cnmfe_modeling.py VK_20250407_a 2025-05-10 tp3-1dpi --analyzed-base /path/to/AnalyzedData
        """,
    )
    parser.add_argument('mouse', help='Mouse ID (e.g., VK_20250407_a)')
    parser.add_argument('date', help='Date (e.g., 2025-05-10)')
    parser.add_argument('tp', help='Timepoint, exactly matching Google Drive naming (e.g., tp3-1dpi)')
    parser.add_argument('--analyzed-base', help='Base path for AnalyzedData (optional)')

    args = parser.parse_args()
    analyzed_base = args.analyzed_base if args.analyzed_base else get_analyzed_base()

    try:
        run_cnmfe(args.mouse, args.date, args.tp, analyzed_base)
        sys.exit(0)
    except Exception as e:
        print(f"\nPipeline failed: {e}")
        sys.exit(1)
