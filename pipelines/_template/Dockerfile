# Skeleton Dockerfile for a new pipeline's container image -- fill in the
# real base image and dependencies before building.

FROM ubuntu:22.04
# Swap for whatever base image you actually need (CUDA, conda, etc).

# Optional: a build-time version tag, set via pipelines.yaml's build_args.
ARG BUILD_SHA=unknown
ENV BUILD_SHA=${BUILD_SHA}

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# rclone, needed if any stage calls `run sync`/rclone from inside a job.
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip \
    && curl https://rclone.org/install.sh | bash \
    && rm -rf /var/lib/apt/lists/*

# --- your actual pipeline dependencies go here ---
# COPY requirements.txt /tmp/requirements.txt
# RUN pip3 install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /workspace
