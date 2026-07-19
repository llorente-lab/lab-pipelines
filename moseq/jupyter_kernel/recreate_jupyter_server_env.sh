#!/bin/bash
# recreate_jupyter_server_env.sh
#
# Rebuilds the server-side Jupyter venv from scratch. This is NOT the
# kernel -- it's the environment that serves the OnDemand Jupyter Notebook
# app's web page (HTML/static JS/websockets). See README.md for the full
# explanation of why this exists separately from the Apptainer container.
#
# Run this if jupyter-server-env/ is ever corrupted, needs relocating, or
# a labmate needs to reproduce it on a different Sherlock account.
#
# Prefer running this on a compute node (sdev / salloc), not a login node --
# some of these packages historically produced flaky/slow builds on shared
# login nodes.

set -euo pipefail

ENV_DIR="${GROUP_HOME:?GROUP_HOME must be set}/moseq/jupyter_kernel/jupyter-server-env"

if [ -d "$ENV_DIR" ]; then
  echo "Refusing to overwrite existing $ENV_DIR -- remove it first if you really want to rebuild:"
  echo "  rm -rf $ENV_DIR"
  exit 1
fi

echo "Creating venv at $ENV_DIR ..."
python3 -m venv --copies "$ENV_DIR"
source "$ENV_DIR/bin/activate"

echo "Upgrading pip ..."
pip install --upgrade pip

echo "Installing pinned packages (see README.md for why each pin exists) ..."
pip install --no-cache-dir \
  "pandas<2.2" \
  "numpy<2.0.0" \
  "notebook<7" \
  "ipywidgets<8.0.0" \
  "ipykernel<6.30" \
  "jupyter-client<8,>=5.3.4" \
  "jupyter_nbextensions_configurator" \
  "qgrid>=1.3.1" \
  "bokeh>=2.4.0,<3.0.0" \
  "jupyter_bokeh>=2.0.3,<3.0.0"

echo "Activating nbextensions ..."
jupyter nbextension install --py jupyter_nbextensions_configurator --sys-prefix
jupyter nbextension enable  --py --sys-prefix widgetsnbextension
jupyter nbextension enable  --py --sys-prefix qgrid
jupyter nbextension install --sys-prefix --symlink --py jupyter_bokeh
jupyter nbextension enable  jupyter_bokeh --py --sys-prefix

echo
echo "Checking for dependency conflicts ..."
pip check || echo "WARNING: pip check reported conflicts above -- review before relying on this env."

echo
echo "Validating nbextensions ..."
jupyter nbextension list

echo
echo "Done. Confirm 'notebook' above the extension list line reports version 6.x:"
pip show notebook | grep -i version

echo
echo "Next steps:"
echo "  1. Confirm all extensions above show 'enabled - Validating: OK'"
echo "  2. In the OnDemand Jupyter Notebook launch form, set 'Custom"
echo "     initialization commands' to:"
echo "       source $ENV_DIR/bin/activate"
echo "  3. Set 'Python version' to 3.9 (must match this venv's base)"
echo "  4. Launch a NEW session (existing sessions won't pick this up)"
