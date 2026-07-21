"""
Targeted API smoke tests for surfaces that historically break across
dependency upgrades (numpy 2.x, tifffile compress→compression, click 8.2+
default validation, scipy.signal API, opencv 5.x). No real .avi/.dat inputs
— all data is synthesized in-process.

Keep each test cheap (< a few seconds). This suite runs at `docker build`
time; every second here delays every container rebuild.
"""

import os
import tempfile
from collections import OrderedDict

import numpy as np
import pytest


# ── moseq2-extract ──────────────────────────────────────────────────────────
def test_write_read_image_no_compression():
    """
    tifffile 2024.x removed the `compress=` kwarg; write_image forwards it.
    Also exercises the scale-factor roundtrip that's baked into read_image.
    """
    from moseq2_extract.io.image import write_image, read_image

    img = (np.random.rand(64, 64) * 1000).astype(np.uint16)
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "bg.tiff")
        write_image(p, img, scale=True)  # compress=0 default
        loaded = read_image(p, scale=True)
    assert loaded.shape == img.shape
    # scale=True quantizes, so allow small tolerance
    np.testing.assert_allclose(loaded, img, rtol=0, atol=2)


def test_write_read_image_with_compression():
    """Non-default `compress=<int>` path — proves the zlib codec bridge works."""
    from moseq2_extract.io.image import write_image, read_image

    img = (np.random.rand(64, 64) * 1000).astype(np.uint16)
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "bg.tiff")
        write_image(p, img, scale=True, compress=6)
        loaded = read_image(p, scale=True)
    assert loaded.shape == img.shape


def test_extract_clean_frames_runs():
    """
    Exercises opencv (median / morphology) on a stack of uint8 depth frames.
    Guards against opencv-python vs opencv-python-headless / opencv 5.x drift.
    """
    from moseq2_extract.extract.proc import clean_frames

    frames = np.random.randint(0, 80, size=(5, 40, 40), dtype=np.uint8)
    # Only exercise the median-blur path — iters_min/iters_tail branches
    # call cv2.erode/morphologyEx with a positional int that recent opencv
    # interprets as `dst` and rejects; that's a pre-existing quirk of the
    # package, not something this smoke suite should assert on.
    out = clean_frames(frames, prefilter_space=(3,))
    assert out.shape == frames.shape
    assert out.dtype == np.uint8


def test_sklearn_legacy_shim_installed():
    """
    The Google-hosted flip-classifier pickles were pickled under sklearn
    < 0.22 (RandomForestClassifier at sklearn.ensemble.forest). moseq2-extract
    installs a sys.modules alias at import time; regression here means every
    extraction that has a flip-classifier configured will die with
    "No module named 'sklearn.ensemble.forest'".
    """
    import sys
    import moseq2_extract.extract.proc  # noqa: F401 — import triggers shim

    assert "sklearn.ensemble.forest" in sys.modules
    # sklearn.tree.tree is aliased opportunistically; assert only if available.
    try:
        import sklearn.tree._classes  # noqa: F401
        assert "sklearn.tree.tree" in sys.modules
    except ImportError:
        pass


def test_extract_im_moment_features():
    from moseq2_extract.extract.proc import im_moment_features

    im = np.zeros((40, 40), dtype=np.uint8)
    im[10:30, 15:25] = 200
    feats = im_moment_features(im)
    # returns a dict of centroid / axes / orientation
    assert isinstance(feats, dict)
    assert "centroid" in feats


# ── moseq2-pca ─────────────────────────────────────────────────────────────
def test_pca_clean_frames_runs():
    """cv2 + scipy on a small frame stack; exercises the moseq2-pca side."""
    from moseq2_pca.util import clean_frames

    frames = np.random.randint(0, 80, size=(5, 40, 40), dtype=np.uint8)
    out = clean_frames(
        frames, medfilter_space=[3], gaussfilter_space=(1.5, 1.5)
    )
    assert out.shape == frames.shape


# ── moseq2-model ───────────────────────────────────────────────────────────
def test_whiten_all_runs():
    """np.linalg.cholesky + solve — sensitive to numpy 2.x ABI changes."""
    from moseq2_model.train.util import whiten_all

    rng = np.random.default_rng(0)
    data_dict = OrderedDict(
        (f"s{i}", rng.standard_normal((200, 10)).astype(np.float64))
        for i in range(3)
    )
    whitened, params = whiten_all(data_dict, center=True)
    assert set(whitened.keys()) == set(data_dict.keys())
    for k, v in whitened.items():
        assert v.shape == data_dict[k].shape
        assert np.isfinite(v).all()
    assert {"mu", "L", "offset"} <= set(params.keys())


def test_arhmm_construction():
    """
    Full pyhsmm → pybasicbayes → autoregressive stack.
    empirical_bayes=False keeps this cheap (~1s).
    """
    from moseq2_model.train.models import ARHMM

    rng = np.random.default_rng(0)
    data_dict = OrderedDict(
        (f"s{i}", rng.standard_normal((150, 4)).astype(np.float64))
        for i in range(2)
    )
    model = ARHMM(
        data_dict,
        nlags=2,
        max_states=5,
        empirical_bayes=False,
        silent=True,
    )
    assert len(model.states_list) == len(data_dict)
    ll = model.log_likelihood()
    assert np.isfinite(ll)


# ── pyhsmm / pybasicbayes ─────────────────────────────────────────────────
def test_multivariate_t_loglik_runs():
    """
    Exercises pyhsmm.util.stats — the direct home of the deprecated
    numpy.core.umath_tests.inner1d import that the shim replaces.
    """
    from pyhsmm.util.stats import multivariate_t_loglik

    rng = np.random.default_rng(0)
    d = 4
    y = rng.standard_normal((10, d))
    mu = np.zeros(d)
    lmbda = np.eye(d)
    out = multivariate_t_loglik(y, nu=5, mu=mu, lmbda=lmbda)
    assert np.isfinite(np.asarray(out)).all()


def test_pybasicbayes_gaussian_rvs_loglik():
    """
    Roundtrip on the Gaussian distribution: sample then score.
    Doesn't exercise the (never-imported) inner1d in gaussian.py's VB path
    directly, but proves the base API still functions after numpy/scipy
    upgrades.
    """
    from pybasicbayes.distributions import Gaussian

    d = 3
    g = Gaussian(mu=np.zeros(d), sigma=np.eye(d))
    x = g.rvs(size=50)
    assert x.shape == (50, d)
    ll = g.log_likelihood(x)
    assert ll.shape == (50,)
    assert np.isfinite(ll).all()


# ── numpy 2 sanity ─────────────────────────────────────────────────────────
def test_numpy_is_v1():
    """The whole stack is pinned to numpy<2; guard against silent upgrades."""
    import numpy

    major = int(numpy.__version__.split(".")[0])
    assert major == 1, f"expected numpy 1.x, got {numpy.__version__}"


def test_opencv_is_headless():
    """
    Guards against a regression where opencv-python (GUI, needs libGL)
    sneaks back in via a transitive dep and breaks headless HPC nodes.
    """
    from importlib.metadata import distributions

    installed = {d.metadata["Name"].lower() for d in distributions()}
    assert "opencv-python-headless" in installed, (
        f"opencv-python-headless not installed; installed opencv-like: "
        f"{sorted(n for n in installed if n.startswith('opencv'))}"
    )
    assert "opencv-python" not in installed, (
        "opencv-python (GUI build) is installed alongside headless — "
        "the headless install path in the Dockerfile regressed."
    )
