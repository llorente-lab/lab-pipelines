FROM continuumio/anaconda3:2024.02-1
# Note: miniconda causes a segfault with pyhsmm Cython extensions, use anaconda3
LABEL org.opencontainers.image.source=https://github.com/llorente-lab/moseq2-app
LABEL org.opencontainers.image.description="MoSeq2 full pipeline: extract, PCA, model, viz, app"

ARG VERSION=unknown
LABEL org.opencontainers.image.revision=$VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/conda/bin:$PATH
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        build-essential gcc g++ git ffmpeg unzip libglib2.0-0 libgomp1 && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://rclone.org/install.sh | bash
RUN conda install -y python=3.11 && conda clean -ay

RUN conda install -y "numpy<2.0.0" "cython>=3" && conda clean -ay

# PDM build backend (used by all 8 packages)
RUN pip install --no-cache-dir pdm-backend

WORKDIR /src
COPY pybasicbayes          ./pybasicbayes
COPY pyhsmm                ./pyhsmm
COPY pyhsmm-autoregressive ./pyhsmm-autoregressive
COPY moseq2-extract        ./moseq2-extract
COPY moseq2-pca            ./moseq2-pca
COPY moseq2-model          ./moseq2-model
COPY moseq2-viz            ./moseq2-viz
COPY moseq2-app            ./moseq2-app


RUN pip install --no-cache-dir --no-build-isolation /src/pybasicbayes
RUN pip install --no-cache-dir "future>=1.0.0" six nose
RUN pip install --no-cache-dir --no-build-isolation --no-deps /src/pyhsmm
RUN pip install --no-cache-dir --no-build-isolation --no-deps /src/pyhsmm-autoregressive
RUN pip install --no-cache-dir --no-build-isolation /src/moseq2-extract
RUN pip install --no-cache-dir --no-build-isolation /src/moseq2-pca
RUN pip install --no-cache-dir --no-build-isolation /src/moseq2-viz
RUN pip install --no-cache-dir --no-build-isolation --no-deps /src/moseq2-model

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

RUN pip install --no-cache-dir --no-build-isolation --no-deps /src/moseq2-app

RUN pip uninstall -y opencv-python && \
    pip install --no-cache-dir opencv-python-headless

RUN python -c "\
import moseq2_extract, moseq2_pca, moseq2_model, moseq2_viz, moseq2_app; \
import cv2; \
print('OK, cv2', cv2.__version__)"

EXPOSE 8888
CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--no-browser"]
