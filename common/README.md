# common/

Shared code used by more than one pipeline. Everything here is intentionally
generic -- no pipeline-specific paths, variable names, or assumptions.

- `job_template.sh` -- `job_init <stage> <project_root>` sets up a stage
  script's status-file JSON + EXIT trap and exports the six thread-count env
  vars (`OMP_NUM_THREADS`, `NUMEXPR_MAX_THREADS`, etc.) so the container's
  numeric libraries match the job's real Slurm allocation. Source it and
  call `job_init` near the top of any `.sbatch` stage script, right after
  parsing that stage's own positional args. See the header comment in the
  file for the full usage pattern. Originally written for Moseq; every
  Moseq stage script uses it, and it's pipeline-agnostic, so any new
  pipeline's stage scripts should use it too instead of hand-rolling the
  same status-file/threading boilerplate.

- `monitor_resources.sh` -- `start_resource_monitor <log_file>
  [interval_seconds]` backgrounds a lightweight CPU/memory TSV sampler for
  the current Slurm job. Sourced automatically by `job_template.sh`; also
  sourced directly by miniscope's `pipeline_common.sh`.

- `apptainer_helpers.sh` -- `define_apptainer_wrappers <SIF_VAR_NAME>`
  defines `apptainer_python`/`apptainer_rclone`/`apptainer_exec` in the
  calling shell, the same three wrapper functions moseq and miniscope's
  `env_setup.sh` each currently hand-write with near-identical bodies. New
  pipelines should call this from their own `env_setup.sh` rather than
  copy-pasting the wrappers again. (Moseq and miniscope's existing
  hand-written versions are left as-is for now -- they work, and swapping
  them for the generator is a separate, lower-value cleanup, not a
  correctness fix.)

## Adding a pipeline

See `pipelines.yaml`'s header comment at the repo root for the full
checklist. In short: `pipelines/<name>/` gets a `Dockerfile`,
`common/env_setup.sh` (sourcing `job_template.sh`/`apptainer_helpers.sh`
from here), `resources.yaml`, and stage scripts; `cli/pipelines/<name>.sh`
implements the naming-convention functions; `.github/tests/tests.yaml`
gets a `<name>:` key; one entry goes into `pipelines.yaml`. No file in this
directory needs to change, and no CI workflow needs to change -- both are
manifest-driven.

## Why so little lives here

Nothing gets written here speculatively. Building shared abstractions
before a second real caller exists tends to guess wrong about what
actually needs to be shared -- this repo already paid for that lesson once
with `pipelines/miniscope/common/reconcile_common.py` (built shared *within*
Miniscope only after the duplication between the MC and CNMF-E
reconciliation scripts was real and visible, not before). Everything above
was promoted here only once Moseq's own copy of the same logic already
existed and the duplication was real, not before.

Remaining candidates, not yet promoted because only one pipeline currently
needs them:

- Sherlock storage-tier-aware env resolution (currently `MINISCOPE_*`-
  prefixed in `pipelines/miniscope/common/env_setup.sh`; Moseq doesn't have
  an equivalent storage-tier concept yet, only `MOSEQ_PROJECTS_BASE`).
- The per-session `logs/` convention (`run_logged()` in
  `pipelines/miniscope/common/pipeline_common.sh`).
- The reconciliation "discover -> filter excluded -> yield eligible" shape
  (the specific done/ready checks would stay pipeline-specific, but the
  shell around them might not).
