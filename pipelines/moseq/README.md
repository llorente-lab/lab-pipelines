# Moseq

Motion-sequencing pipeline (Datta lab `moseq2` stack), containerized and
deployed the same way as Miniscope -- see the top-level `README.md` for the
deploy mechanism and `cli/README.md` for the `run moseq ...` command
reference. This file covers Moseq-specific dev setup, mainly how to test a
source fix without a full container rebuild.

## Dev-testing without a full rebuild

A full cycle (edit a vendored package, `docker buildx build --push`,
`apptainer pull` onto Sherlock, retest) is slow -- the container has a full
conda env plus 8 compiled packages. Two faster paths exist; neither touches
this pipeline's `Dockerfile`.

### `scripts/moseq_dev_venv_setup.sh` -- bare venv, no container

Fastest for a pure-Python fix with nothing else in the way.

```bash
bash scripts/moseq_dev_venv_setup.sh
source $HOME/moseq-dev-venv/bin/activate
```

Mirrors the Dockerfile's package pins (numpy<2, scikit-learn 1.2.x, install
order). Clones `moseq2-extract` editable by default under `$HOME/dev/` --
add others to the `EDITABLE_PACKAGES` array at the top of the script.
Also registers a `--user`-scoped Jupyter kernel ("Moseq (dev venv)").

Must match the container's Python 3.11 closely, or you'll hit
builds-from-source for packages that only ship prebuilt wheels for
specific versions (scikit-learn 1.2.2, pinned for flip-classifier pickle
compatibility, has no 3.12 wheel). If Sherlock lacks a `python/3.11.x`
module, `uv python install 3.11` ([astral.sh/uv](https://astral.sh/uv), a
static binary, no root/module needed) gets a real prebuilt 3.11.

Good for: pure-Python logic bugs that don't need the container's exact
compiled ABI.

### `apptainer_dev_exec` -- real container, editable packages bind-mounted in

Defined in `common/env_setup.sh`. Runs against the actual deployed `.sif`
(same compiled numpy/opencv/pyhsmm ABI as production), binding
`$MOSEQ_DEV_DIR` (default `$HOME/moseq-dev`) into the container at
`/moseq-dev` and putting whichever package checkouts exist there first on
`PYTHONPATH`.

```bash
git clone https://github.com/llorente-lab/moseq2-pca.git ~/moseq-dev/moseq2-pca
# edit ~/moseq-dev/moseq2-pca/... directly
apptainer_dev_exec moseq2-pca train-pca ...
```

Only packages that exist under `$MOSEQ_DEV_DIR` get added to `PYTHONPATH`;
everything else resolves to the container's own copy. Covers all 8
vendored packages (`moseq2-extract`, `moseq2-pca`, `moseq2-model`,
`moseq2-viz`, `moseq2-app`, `pyhsmm`, `pyhsmm-autoregressive`,
`pybasicbayes`).

**Compiled (Cython/C++) extensions need one extra step.** `pip install -e`
on `pyhsmm-autoregressive` (the one package with a real compiled
extension, `autoregressive/messages.pyx`) doesn't always leave the built
`.so` inside the `autoregressive/` package directory where Python needs
it:

```bash
find ~/moseq-dev/pyhsmm-autoregressive -iname "messages*.so"
# if it's in the repo root or a build/ subdir instead of autoregressive/, copy it in:
cp ~/moseq-dev/pyhsmm-autoregressive/messages.cpython-311-x86_64-linux-gnu.so \
   ~/moseq-dev/pyhsmm-autoregressive/autoregressive/
apptainer_dev_exec python3 -c "import autoregressive.messages; print('ok')"
```

Testing an arbitrary pip dependency (not one of the 8 vendored packages)
works the same way, installed to a target directory instead of a git
checkout:

```bash
apptainer_exec pip install --no-cache-dir --force-reinstall \
  --target ~/moseq-dev/pip-overrides "msgpack>=1.0.7"
apptainer exec \
  --bind "${SCRATCH:-/tmp},${GROUP_SCRATCH:-/tmp},${GROUP_HOME:-/tmp}" \
  --bind ~/moseq-dev:/moseq-dev \
  --env "PYTHONPATH=/moseq-dev/pip-overrides" \
  "$MOSEQ_SIF" python3 -c "import msgpack; print(msgpack.version)"
```

Good for: anything needing the container's real compiled environment --
most production bugs are dependency-version drift that only shows up
against the real installed stack.

### Once a fix is confirmed

Commit + push from the same checkout under `$MOSEQ_DEV_DIR`/`$HOME/dev`
to the `llorente-lab` fork's `main` branch. The Dockerfile already tracks
`@main` for all 8 packages, so the next build picks it up -- but Docker's
layer cache won't invalidate on its own, so force a re-pull with
`--no-cache` or a bumped `VERSION` build-arg.
