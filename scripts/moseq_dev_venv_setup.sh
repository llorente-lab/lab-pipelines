#!/bin/bash
# One-time (rerunnable) bootstrap for a local dev venv that mirrors the
# moseq container's package installs, WITHOUT the container -- lets you
# edit a package's source directly and re-test immediately, no
# docker build / apptainer pull cycle. Mirrors moseq/Dockerfile's install
# order and pins exactly; if the Dockerfile changes, update this to match.
#
# Usage:
#   bash dev_venv_setup.sh
#   source $GROUP_SCRATCH/moseq-dev-venv/bin/activate
#
# Editable packages (the ones actually being debugged) are cloned into
# dev/<pkg> and installed with `pip install -e`, so edits take effect
# immediately with no reinstall step. Everything else installs straight
# from @main via git+https, same as the Dockerfile, since you're not
# actively editing those.
#
# When a fix in one of the editable packages is confirmed working here,
# commit + push it from its dev/<pkg> checkout straight to the
# llorente-lab fork's main branch -- the Dockerfile already tracks @main,
# so the next container build picks it up automatically (remember the
# @main git-cache gotcha: use --no-cache or bump VERSION to force the
# build to actually re-pull, since Docker won't invalidate the layer on
# its own just because upstream changed).

# Registers a Jupyter kernel pointed at this venv (see bottom of script),
# so it shows up as a selectable kernel in Sherlock's Open OnDemand Jupyter
# app / any other Jupyter frontend -- lets you test notebook-driven work
# against your live editable-package edits too, not just plain scripts.

set -euo pipefail

# Defaulting to $HOME here (not $GROUP_SCRATCH) since that's where you're
# running this from. Fine for a venv -- it's just packages/symlinks, not
# large data -- but keep an eye on your home quota if you end up with
# several of these; $GROUP_SCRATCH is still the better place for anything
# data-heavy (session data, project outputs).
VENV_DIR="${VENV_DIR:-$HOME/moseq-dev-venv}"
DEV_DIR="${DEV_DIR:-$HOME/dev}"
KERNEL_NAME="${KERNEL_NAME:-moseq-dev}"
KERNEL_DISPLAY_NAME="${KERNEL_DISPLAY_NAME:-Moseq (dev venv)}"

# Packages you're actively editing -- cloned + pip install -e.
# Edit this list as whatever you're debugging changes.
EDITABLE_PACKAGES=(
  moseq2-extract
)

# Everything else, installed straight from @main like the container.
# (name:no-deps) -- no-deps mirrors which Dockerfile RUNs pass --no-deps.
PINNED_PACKAGES=(
  "pybasicbayes:no"
  "pyhsmm:yes"
  "pyhsmm-autoregressive:yes"
  "moseq2-pca:no"
  "moseq2-viz:no"
  "moseq2-model:yes"
  "moseq2-app:yes"
)

echo "=== creating venv at $VENV_DIR ==="
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --upgrade pip

echo "=== pinning numpy/cython/sklearn/pdm-backend (must match Dockerfile) ==="
pip install "numpy<2.0.0" "cython>=3"
pip install "scikit-learn>=1.2,<1.3"
pip install pdm-backend
pip install "future>=1.0.0" six nose

echo "=== cloning + editable-installing packages under active development ==="
mkdir -p "$DEV_DIR"
for pkg in "${EDITABLE_PACKAGES[@]}"; do
  repo_dir="$DEV_DIR/$pkg"
  if [ ! -d "$repo_dir" ]; then
    git clone "https://github.com/llorente-lab/${pkg}.git" "$repo_dir"
  else
    echo "  $pkg already cloned at $repo_dir -- not re-cloning (pull manually if you want upstream changes)"
  fi
  pip install --no-build-isolation -e "$repo_dir"
done

echo "=== installing remaining packages from @main (same as container) ==="
for entry in "${PINNED_PACKAGES[@]}"; do
  pkg="${entry%%:*}"
  no_deps="${entry##*:}"
  # skip anything already installed editable above
  already_editable=0
  for e in "${EDITABLE_PACKAGES[@]}"; do
    [ "$e" = "$pkg" ] && already_editable=1
  done
  [ "$already_editable" -eq 1 ] && continue

  if [ "$no_deps" = "yes" ]; then
    pip install --no-build-isolation --no-deps "git+https://github.com/llorente-lab/${pkg}.git@main"
  else
    pip install --no-build-isolation "git+https://github.com/llorente-lab/${pkg}.git@main"
  fi
done

echo "=== app extras ==="
pip install \
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

echo "=== opencv headless swap (same as container) ==="
pip uninstall -y opencv-python 2>/dev/null || true
pip install opencv-python-headless "numpy<2.0.0"

echo "=== registering Jupyter kernel: $KERNEL_NAME ==="
# ipykernel isn't guaranteed to be pulled in transitively by the "jupyter"
# metapackage above, so install it explicitly rather than assuming.
pip install ipykernel
python -m ipykernel install --user \
  --name "$KERNEL_NAME" \
  --display-name "$KERNEL_DISPLAY_NAME"
# --user installs to ~/.local/share/jupyter/kernels/$KERNEL_NAME, which is
# exactly where Sherlock's Open OnDemand Jupyter app looks for kernels --
# no extra registration step needed to see it there. Note this is a
# DIFFERENT kernel from the one moseq/jupyter_kernel/ registers for the
# apptainer-backed container -- this one imports straight from the venv,
# no apptainer exec involved, so edits under $DEV_DIR take effect with
# just a kernel restart, not a container rebuild.

echo ""
echo "done. activate with:"
echo "  source $VENV_DIR/bin/activate"
echo ""
echo "jupyter kernel '$KERNEL_NAME' ($KERNEL_DISPLAY_NAME) registered --"
echo "select it from Sherlock OnDemand's Jupyter app, or run:"
echo "  jupyter kernelspec list"
echo "to confirm it's there."
echo ""
echo "editable packages (edit source, test immediately, no reinstall needed):"
for pkg in "${EDITABLE_PACKAGES[@]}"; do
  echo "  $DEV_DIR/$pkg"
done
