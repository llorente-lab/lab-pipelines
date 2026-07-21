# MoSeq2 Jupyter Environment on Sherlock

This directory contains the Jupyter infrastructure for running MoSeq2 pipelines
via Sherlock OnDemand's "Jupyter Notebook" app. There are **two separate
Python environments** involved — this is the single most important thing to
understand before touching anything here.

## The two environments

1. **The kernel** — runs *inside* the Apptainer container at `$MOSEQ_SIF`.
   This executes your actual notebook code: `import moseq2_model`, PCA/model
   training, etc. Launched via `moseq_kernel_wrapper.sh`, registered as the
   "MoSeq2 (Apptainer)" kernel.

2. **The server** — runs on the *host*, using Sherlock's system Python
   (selected via the OnDemand form's "Python version" field, currently
   Python 3.9). This serves the notebook web page itself: the HTML, static
   JS files, and websocket connections your browser talks to. It has
   nothing to do with the container.

Widget rendering (`ipywidgets`, `qgrid`, `jupyter_bokeh`) requires **both**
environments to have compatible, correctly-enabled extensions — the kernel
side sends widget state over the comm channel, but the *server* is what
actually serves the JS that renders it in your browser. If widgets stop
rendering, check the server environment first (`jupyter-server-env/`,
below) — it's the one people forget about, since the "Python version"
dropdown in the OnDemand form is easy to miss.

## Why classic Notebook, not JupyterLab

`qgrid` (used throughout `moseq2-app`'s GUI widgets) has no JupyterLab/
labextension build — it only works via classic Notebook's `nbextension`
system. `notebook<7` is pinned in both environments below for this reason.
If `qgrid` is ever dropped in favor of a maintained alternative
(`ipydatagrid`, `itables`), this constraint goes away and JupyterLab
becomes viable again.

## Files in this directory

- `moseq_kernel_wrapper.sh` — launches the kernel inside the container.
  Referenced by `kernels/moseq2-apptainer/kernel.json`.
- `jupyter-server-env/` — venv for the *server* (see above). Built with
  Python 3.9 to match Sherlock's OnDemand Jupyter app's "Python version"
  setting. See `recreate_jupyter_server_env.sh` to rebuild it from scratch.
- `recreate_jupyter_server_env.sh` — recreates `jupyter-server-env/` from
  nothing. Run this if the venv is ever corrupted, needs relocating, or
  needs a Python version bump.

## Setting up a new OnDemand session

In the Jupyter Notebook app launch form, set **"Custom initialization
commands"** to:

```bash
source $GROUP_HOME/moseq/jupyter_kernel/jupyter-server-env/bin/activate
```

Python version: **3.9** (must match what `jupyter-server-env` was built
with — see `recreate_jupyter_server_env.sh` if this ever changes).

Launch a **new** session after any change here — an existing running
session will not pick up initialization command changes.

## Known-good pinned versions (server-side venv)

These pins exist for specific, non-obvious reasons — don't casually bump
them:

| Package | Constraint | Why |
|---|---|---|
| `notebook` | `<7` | qgrid needs classic-notebook nbextensions, not labextensions |
| `ipywidgets` | `<8.0.0` | qgrid was never updated for ipywidgets 8's API |
| `bokeh` | `>=2.4.0,<3.0.0` | bokeh 3.x's enum code crashes under Python 3.9's `typing` |
| `jupyter_bokeh` | `>=2.0.3,<3.0.0` | jupyter_bokeh 3+ requires bokeh 3.x's `bokeh.core.serialization` |
| `pandas` | `<2.2` | pandas >=2.2 has no prebuilt wheel for Python 3.9, fails to compile on login nodes |
| `numpy` | `<2.0.0` | pandas 2.1.x requires numpy <2 |
| `ipykernel` | `<6.30` | newer ipykernel wants `jupyter-client>=8`, conflicts with notebook<7's `jupyter-client<8` pin |
| `jupyter-client` | `<8,>=5.3.4` | pulled in by `notebook<7`; must stay <8 |

## Debugging widget rendering issues

If widgets show as text (`IntSlider(value=0)`) instead of rendering:

1. Open browser DevTools → Console, look for `404` on `.../nbextensions/...`
   or `Class jupyter.widget not found in registry`.
2. If found: the **server** environment's nbextensions aren't active. Check
   `jupyter-server-env` was actually sourced (`which jupyter` inside an
   OnDemand terminal should point into `jupyter-server-env/bin/`).
3. `jupyter nbextension list` (with `jupyter-server-env` active) should
   show `jupyter_bokeh`, `qgrid`, `jupyter-js-widgets`, and
   `nbextensions_configurator` all `enabled` / `Validating: OK`.
4. If missing/broken, see `recreate_jupyter_server_env.sh`.
5. Remember: kernel restarts do **not** reload the browser page. A stale
   nbextension config requires a full page reload (or new session) to
   take effect — kernel-only restarts will not fix it.

## Kernel-side notes

- `kernels/moseq2-apptainer/kernel.json` tells Jupyter to launch the kernel
  via `moseq_kernel_wrapper.sh -f {connection_file}`. The nesting matters:
  Jupyter's kernel discovery looks for `<dir>/kernels/<name>/kernel.json`
  under each `JUPYTER_PATH` entry. `deploy_check.sh` checks this path
  specifically to catch regressions.
- `common/env_setup.sh` adds this directory to `JUPYTER_PATH` so kernel
  updates apply automatically on the next deploy via the `current` symlink.
- Kernels inherit the server process's environment, so `MOSEQ_SIF` must be
  set before the Jupyter server starts. The OnDemand "Custom initialization
  commands" field (above) handles this via the server-env activate line,
  which in turn sources `env_setup.sh` indirectly through `~/.bashrc`.
