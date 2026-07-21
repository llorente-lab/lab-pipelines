# common/

Shared code used by more than one pipeline. Everything here is
intentionally generic -- no pipeline-specific paths, variable names, or
assumptions.

- `job_template.sh` -- `job_init <stage> <project_root>` sets up a stage
  script's status-file JSON + EXIT trap and exports the thread-count env
  vars (`OMP_NUM_THREADS`, etc.) so the container's numeric libraries match
  the job's real Slurm allocation. Source it and call `job_init` near the
  top of any `.sbatch` stage script, after parsing that stage's positional
  args. Every Moseq stage script uses it; new pipelines should too.
- `monitor_resources.sh` -- `start_resource_monitor <log_file>
  [interval_seconds]` backgrounds a lightweight CPU/memory TSV sampler for
  the current Slurm job. Sourced automatically by `job_template.sh`; also
  used directly by miniscope's `pipeline_common.sh`.
- `apptainer_helpers.sh` -- `define_apptainer_wrappers <SIF_VAR_NAME>`
  defines `apptainer_python`/`apptainer_rclone`/`apptainer_exec` in the
  calling shell. New pipelines should call this from their own
  `env_setup.sh` rather than copy-pasting the wrappers (moseq/miniscope's
  existing hand-written versions are left as-is -- swapping them is a
  separate, lower-value cleanup, not a correctness fix).

## Adding a pipeline

See `pipelines.yaml`'s header at the repo root for the full checklist. In
short: `pipelines/<name>/` gets a `Dockerfile`, `common/env_setup.sh`
(sourcing `job_template.sh`/`apptainer_helpers.sh` from here),
`resources.yaml`, and stage scripts; `cli/pipelines/<name>.sh` implements
the naming-convention functions; `.github/tests/tests.yaml` gets a
`<name>:` key; one entry goes into `pipelines.yaml`. Nothing in this
directory or in CI needs to change -- both are manifest-driven.

## Why so little lives here

Nothing gets written here speculatively -- only promoted once a second
real pipeline actually duplicated it (same discipline that led to
`pipelines/miniscope/common/reconcile_common.py` being pulled out within
Miniscope itself, once the MC/CNMF-E reconciliation duplication was real).

Remaining candidates, not yet promoted (only one pipeline needs them so far):

- Sherlock storage-tier-aware env resolution (`MINISCOPE_*`-prefixed in
  miniscope's `env_setup.sh`; Moseq has no equivalent concept yet, just
  `MOSEQ_PROJECTS_BASE`).
- The per-session `logs/` convention (`run_logged()` in miniscope's
  `pipeline_common.sh`).
- The reconciliation "discover -> filter excluded -> yield eligible" shape
  (the done/ready checks would stay pipeline-specific, but the shell
  around them might not).
