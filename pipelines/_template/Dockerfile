# Reference Dockerfile for a new pipeline's container image. This is a
# skeleton, not something you build as-is -- fill in the real base image and
# package installs for your actual pipeline before using it.

FROM ubuntu:22.04
# ^ pick whatever real base image your pipeline needs (a CUDA image, a conda
#   base image, etc.) -- this is just a placeholder.

# Example: accept a build-time ref/version, matching the "build_args" field
# your pipelines.yaml entry can pass in (see pipelines.yaml's own header
# comment for the exact mechanism). Optional -- drop this if you don't need
# a build-time-configurable version.
ARG BUILD_SHA=unknown
ENV BUILD_SHA=${BUILD_SHA}

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# rclone is required inside the container if your pipeline's stages (or
# common/sync.sh-style wrappers) run `run sync`/`rclone` from inside a job --
# see common/env_setup.sh's apptainer_rclone() pattern in moseq/miniscope.
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip \
    && curl https://rclone.org/install.sh | bash \
    && rm -rf /var/lib/apt/lists/*

# --- your actual pipeline dependencies go here ---
# COPY requirements.txt /tmp/requirements.txt
# RUN pip3 install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /workspace
