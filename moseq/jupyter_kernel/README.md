# Moseq Jupyter kernel (Apptainer-backed)

This directory registers a Jupyter kernelspec, "MoSeq2 (Apptainer)", that
lets Sherlock OnDemand's standard Jupyter app run notebook cells inside the
Moseq container, without OnDemand needing any custom app configuration.

## How it works

- `kernels/moseq2-apptainer/kernel.json` tells Jupyter to launch the kernel
  process via `moseq_kernel_wrapper.sh -f {connection_file}` instead of a
  bare `python`. **The nesting matters**: Jupyter's kernel discovery looks
  for `<dir>/kernels/<name>/kernel.json` under each `JUPYTER_PATH` entry,
  not a bare `kernel.json` directly in the directory itself. An earlier
  version of this had `kernel.json` sitting directly in `jupyter_kernel/`
  and `jupyter kernelspec list` silently ignored it, no error, it just
  never appeared. `deploy_check.sh` now checks the file at its correct
  nested path specifically to catch a regression of this.
- The wrapper `exec`s `apptainer exec ... python -m ipykernel_launcher`,
  so only the kernel (the process executing your code cells) runs inside
  the container. The outer Jupyter server, notebook UI, auth token, and
  port forwarding are all handled by OnDemand exactly as it already does
  for any other kernel, we're not replacing any of that.
- `common/env_setup.sh` adds this directory (`jupyter_kernel/`, the parent
  of `kernels/`) to `JUPYTER_PATH`, which is how Jupyter's kernel discovery
  finds it. Because this whole directory is deployed through the normal
  GitOps `current` symlink, kernel updates (new image version, wrapper
  script changes) apply automatically on the next deploy, no per-user
  re-registration.

## Open question, needs verification on Sherlock

Jupyter kernels inherit the environment of the server process that spawns
them. That means `MOSEQ_SIF`, `JUPYTER_PATH`, `RCLONE_CONFIG`, etc. all need
to already be exported in the shell OnDemand uses to start the Jupyter
server, which depends on `~/.bashrc` (or wherever `env_setup.sh` is sourced
from, per `cli/setup.sh`) actually running before that server starts.

Some OnDemand launch scripts run as non-interactive/non-login shells and
skip `.bashrc` entirely. **Not yet confirmed which behavior Sherlock's
Jupyter app has.**

To check: launch a plain OnDemand Jupyter session, open a terminal inside
it (or a notebook cell running `!echo $MOSEQ_SIF` / `!echo $PATH`), and
confirm `MOSEQ_SIF` is set and `cli/` is on `PATH`. If it's empty:
- Check whether OnDemand's Jupyter app has a "Custom environment setup"
  or "Extra environment variables" field in its submission form, some
  OnDemand app configs let you source a script or set vars directly
  there rather than relying on shell startup files.
- Failing that, MOSEQ_SIF could be hardcoded directly into
  `moseq_kernel_wrapper.sh` instead of read from the environment, at the
  cost of losing the single-source-of-truth-in-env_setup.sh property.

## Manual test (bypassing OnDemand entirely)

From a Sherlock shell with `env_setup.sh` sourced:

```bash
jupyter kernelspec list          # should show "moseq2-apptainer" or similar
echo $MOSEQ_SIF                  # should not be empty
$MOSEQ_ROOT_DIR/jupyter_kernel/moseq_kernel_wrapper.sh -f /dev/null
# expected: fails fast with a connection-file error from ipykernel itself
# (proves apptainer exec + ipykernel_launcher actually runs), not a
# "command not found" or "MOSEQ_SIF not set" error.
```
