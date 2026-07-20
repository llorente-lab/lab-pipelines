# Moseq

Motion-sequencing pipeline (Datta lab `moseq2` stack), containerized and
deployed the same way as Miniscope -- see the top-level `README.md` for the
shared deploy mechanism and `cli/README.md` for the `run moseq ...` command
reference. This file covers Moseq-specific setup, most importantly how to
test a source fix without waiting on a full container rebuild.

## Dev-testing without a full rebuild

A full cycle -- edit a vendored package's source, `docker buildx build
--push`, `apptainer pull` onto Sherlock, retest -- is slow (the container
has a full conda env plus 8 compiled packages) and, for a while this
project, was blocked entirely by Sherlock's fixed `ulimit -u 512` fighting
`apptainer pull`'s internal `mksquashfs`/`proot` step. Two faster paths
exist for iterating on a fix before committing to that full cycle. Neither
requires touching `moseq/Dockerfile`.

### `scripts/moseq_dev_venv_setup.sh` -- bare venv, no container at all

Fastest option for a pure-Python fix you want to test with nothing else in
the way -- no Apptainer, no Sherlock-specific paths, just Python.

```bash
bash scripts/moseq_dev_venv_setup.sh
source $HOME/moseq-dev-venv/bin/activate
```

Mirrors the Dockerfile's exact package pins (numpy<2, `scikit-learn`
1.2.x, install order). One package is cloned editable by default
(`moseq2-extract`, under `$HOME/dev/`) -- add others to the
`EDITABLE_PACKAGES` array at the top of the script as needed. Also
registers a `--user`-scoped Jupyter kernel ("Moseq (dev venv)"), private
to whoever runs it.

**Watch the Python version.** This has to match the container's Python
3.11 as closely as possible, or you'll hit builds-from-source for packages
that only ship prebuilt wheels for specific versions (`scikit-learn`
1.2.2, pinned for the flip-classifier pickle compatibility, has no 3.12
wheel -- discovered the hard way trying 3.9 first, too old for some
syntax, then 3.12, which broke `scikit-learn`/`scipy` entirely and
cascaded into needing a system `OpenBLAS` that isn't there). If Sherlock
doesn't have a `python/3.11.x` module, `uv python install 3.11` (via
[astral.sh/uv](https://astral.sh/uv), a single static binary, no root/
module needed) gets a real prebuilt 3.11 without relying on Sherlock's
module system at all.

Good for: pure-Python logic bugs where you don't need the exact compiled
ABI the container has (this is how the `tifffile`/`sklearn` shim/
`read_image` bugs got iterated on).

### `apptainer_dev_exec` -- real container, editable packages bind-mounted in

Defined in `moseq/common/env_setup.sh`. Runs against the actual deployed
`.sif` (same compiled numpy/opencv/pyhsmm ABI as production), but binds
`$MOSEQ_DEV_DIR` (default `$HOME/moseq-dev`) into the container at
`/moseq-dev` and puts whichever package checkouts exist there first on
`PYTHONPATH` -- so Python imports your locally edited source instead of
the copy baked into the image.

```bash
git clone https://github.com/llorente-lab/moseq2-pca.git ~/moseq-dev/moseq2-pca
# edit ~/moseq-dev/moseq2-pca/... directly
apptainer_dev_exec moseq2-pca train-pca ...
```

Only packages that actually exist under `$MOSEQ_DEV_DIR` get added to
`PYTHONPATH` -- everything else still resolves to the container's own
copy. Covers all 8 vendored packages (`moseq2-extract`, `moseq2-pca`,
`moseq2-model`, `moseq2-viz`, `moseq2-app`, `pyhsmm`,
`pyhsmm-autoregressive`, `pybasicbayes`).

**Compiled (Cython/C++) extensions need one extra step.** For a pure-Python
package this just works. For `pyhsmm-autoregressive` specifically (the one
package in this stack with a real compiled extension,
`autoregressive/messages.pyx` wrapping Eigen-based HMM message-passing
code), `pip install -e` compiles the `.so` but doesn't always leave it
inside the `autoregressive/` package directory where Python needs to find
it as a submodule -- check and fix if needed:

```bash
find ~/moseq-dev/pyhsmm-autoregressive -iname "messages*.so"
# if it's sitting in the repo root or a build/ subdir instead of inside
# autoregressive/, copy it in:
cp ~/moseq-dev/pyhsmm-autoregressive/messages.cpython-311-x86_64-linux-gnu.so \
   ~/moseq-dev/pyhsmm-autoregressive/autoregressive/
apptainer_dev_exec python3 -c "import autoregressive.messages; print('ok')"
```

Testing an arbitrary **pip dependency** (not one of the 8 vendored
packages -- e.g. bumping `msgpack` to check a `distributed`/dask bug)
works with the same bind, installed to a target directory instead of a git
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

Good for: anything that needs the container's real compiled environment --
which in practice has been most of the bugs actually hit in production
(dependency-version drift only shows up against the real installed stack,
not a from-scratch venv).

### Once a fix is confirmed

Commit + push from the same checkout under `$MOSEQ_DEV_DIR`/`$HOME/dev`
straight to the `llorente-lab` fork's `main` branch. The Dockerfile
already tracks `@main` for all 8 packages, so the next real build picks it
up automatically -- but remember Docker's layer cache won't invalidate on
its own just because upstream moved (the `git+https://...@main` line's
text never changes), so force a real re-pull with `--no-cache` or a
bumped `VERSION` build-arg on that next build.
