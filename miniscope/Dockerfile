FROM python:3.9-slim

# System deps: build tools + git (for pip install from git), ffmpeg (CaImAn uses it
# for video I/O), libgl1 + libglib2.0-0 (opencv-python, a CaImAn dep, needs these
# to import at all on minimal Debian images), curl (to fetch rclone's installer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# rclone: motion_correct.py shells out to it directly (run_sync_if_needed),
# and sync.sh calls it too, so it has to live inside the image, not just on the host.
RUN curl https://rclone.org/install.sh | bash

RUN echo "numpy<2" > /tmp/constraints.txt
ENV PIP_CONSTRAINT=/tmp/constraints.txt

# you check `pip freeze | grep -i caiman` in your ~/caiman venv on Sherlock
ARG CAIMAN_REF=2956b1c1d9c4c5fdffbca38b2538924010308e2d
RUN pip install --no-cache-dir git+https://github.com/flatironinstitute/CaImAn.git@${CAIMAN_REF}


# CaImAn pulls in opencv-python, which drags GUI/X11 deps we don't need on a
# non-interactive cluster. Swap for the headless build.
RUN pip uninstall -y opencv-python && \
    pip install --no-cache-dir opencv-python-headless

# Extras imported directly by the pipeline scripts, not covered by CaImAn's
# own dependency chain: psutil (memory logging), Pillow (PNG saving),
# roifile (FIJI/ImageJ ROI parsing), joblib (model save/load), tqdm (progress bars)
RUN pip install --no-cache-dir psutil Pillow roifile joblib tqdm