FROM continuumio/anaconda3:2024.02-1
# Note: miniconda causes a segfault with pyhsmm Cython extensions, use anaconda3
USER root
LABEL org.opencontainers.image.source=https://github.com/llorente-lab/moseq2-app
LABEL org.opencontainers.image.description="MoSeq2 full pipeline: extract, PCA, model, viz, app"

ARG VERSION=unknown
LABEL org.opencontainers.image.revision=$VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/conda/bin:$PATH

# System deps: build tools + ffmpeg (video I/O). No libgl1/mesa here on
# purpose, we install opencv-python-headless below so there's no GUI/libGL
# dependency to satisfy on a headless HPC node in the first place.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        build-essential gcc g++ git ffmpeg unzip libglib2.0-0 libgomp1 && \
    rm -rf /var/lib/apt/lists/*

# rclone, for pulling/pushing session data to/from Drive from inside the
# container, same pattern as the CaImAn image.
RUN curl https://rclone.org/install.sh | bash

# Pin Python 3.11 (satisfies >=3.9,<3.13 across all packages)
RUN conda install -y python=3.11 && conda clean -ay

# numpy<2 and Cython must be present before any pip build step:
# pybasicbayes/pyhsmm list them as build-system requires
RUN conda install -y "numpy<2.0.0" "cython>=3" && conda clean -ay

# PDM build backend (used by all 8 packages)
RUN pip install --no-cache-dir pdm-backend

# ── Install in dependency order ──────────────────────────────────────────────
# 1. pybasicbayes — no internal deps; full install
RUN pip install --no-cache-dir --no-build-isolation \
    "git+https://github.com/llorente-lab/pybasicbayes.git@main"

# 2. pyhsmm external deps not in anaconda base
RUN pip install --no-cache-dir "future>=1.0.0" six nose

# 3. pyhsmm — depends on pybasicbayes via git+https; --no-deps skips the pull
RUN pip install --no-cache-dir --no-build-isolation --no-deps \
    "git+https://github.com/llorente-lab/pyhsmm.git@main"

# 4. pyhsmm-autoregressive — depends on pyhsmm+pybasicbayes via git+https
RUN pip install --no-cache-dir --no-build-isolation --no-deps \
    "git+https://github.com/llorente-lab/pyhsmm-autoregressive.git@main"

# 5. moseq2-extract — no internal moseq2 deps; full install
RUN pip install --no-cache-dir --no-build-isolation \
    "git+https://github.com/llorente-lab/moseq2-extract.git@main"

# 6. moseq2-pca — no internal moseq2 deps; full install
RUN pip install --no-cache-dir --no-build-isolation \
    "git+https://github.com/llorente-lab/moseq2-pca.git@main"

# 7. moseq2-viz — no internal moseq2 deps; full install
RUN pip install --no-cache-dir --no-build-isolation \
    "git+https://github.com/llorente-lab/moseq2-viz.git@main"

# 8. moseq2-model — depends on pyhsmm stack via git+https; --no-deps skips the pull
RUN pip install --no-cache-dir --no-build-isolation --no-deps \
    "git+https://github.com/llorente-lab/moseq2-model.git@main"

# 9. moseq2-app external deps not yet covered by the packages above
RUN pip install --no-cache-dir \
    "fastparquet>=0.4.1" \
    "holoviews>=1.14.7" \
    "ipython>=7.14.0" \
    "ipywidgets<8.0.0" \
    "jinja2>=3.0.1" \
    "jupyter-bokeh>=2.0.3" \
    "jupyter>=1.0.0" \
    "panel>=0.12.6" \
    "plotly>=4.14.3" \
    "qgrid>=1.3.1"

# 10. moseq2-app — all deps satisfied; --no-deps skips internal git+https pulls
RUN pip install --no-cache-dir --no-build-isolation --no-deps \
    "git+https://github.com/llorente-lab/moseq2-app.git@main"

# install np and headless cv python i
RUN pip uninstall -y opencv-python && \
    pip install --no-cache-dir opencv-python-headless "numpy<2.0.0"

# Fail the build here, not three weeks from now on Sherlock, if any package's
# import chain is broken.
RUN python -c "\
import moseq2_extract, moseq2_pca, moseq2_model, moseq2_viz, moseq2_app; \
import cv2; \
print('OK, cv2', cv2.__version__)"

# Jupyter notebook server. Deliberately NOT hardcoding an empty
# token/password here: Sherlock's Open OnDemand Jupyter app manages its own
# token and reverse-proxy auth and expects Jupyter to respect it, disabling
# auth in the image would fight that. For manual/local testing, run with
# `--NotebookApp.token=''` as an override on the docker/apptainer command
# line instead of baking it into the image.
EXPOSE 8888
CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--no-browser"]
