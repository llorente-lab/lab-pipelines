# Pipeline template

A reference scaffold for adding a new pipeline to this repo. This directory is
never referenced by `pipelines.yaml`, so it's completely inert -- nothing
discovers or runs it automatically. Copy it, rename things, and start filling
in real logic.

## What you get for free (don't reimplement these)

- **Resource flags** (`--partition`/`--exclusive`/`--cpus-per-task`/`--mem`/`--time`)
  come from `cli/estimate_resources.py`, driven entirely by your `resources.yaml`.
  Nothing pipeline-specific to write here beyond the YAML itself.
- **Job history + status** come from sourcing `common/job_template.sh` in your
  `.sbatch` scripts (`job_init "<stage>" "$SOME_ROOT"` at the top). This writes
  both `status/<stage>.json` (latest run) and `status/history.jsonl`
  (append-only) with zero extra code.
- **A dashboard** comes from `common/dashboard.py`, as long as you record each
  submission to `status/jobs.jsonl` (see `_sbatch_submit` in `cli/resources.sh`
  if you're submitting from bash, or `_record_job`-style helper if from Python
  -- see `pipelines/moseq/common/submit_moseq.py` for that pattern).
- **Data syncing** (Drive <-> Sherlock) should go through `run sync <src> <dst>
  [rclone flags...]` (a generic wrapper already on `cli/run`), not a
  pipeline-specific rclone invocation. See `pipelines/miniscope/common/sync.sh`
  for an example of a thin wrapper that just computes paths/flags and calls it.
- **CI (build/test) and deploy discovery** come entirely from one entry in the
  repo root's `pipelines.yaml` -- see that file's own header comment for the
  exact fields. No workflow file needs editing.

## What you still have to write by hand

- `resources.yaml` -- see the one in this directory, one stage per compute job.
- `common/env_setup.sh` -- see the one in this directory. Exports your
  container path, puts `run` on `PATH`, defines any `apptainer_*` helpers your
  stage scripts need.
- `cli/pipelines/<name>.sh` -- see `_template.sh` next to this README (lives
  under `cli/pipelines/` in the real repo, not here) for the exact functions
  `run` expects: `cmd_<name>`, `cmd_logs_<name>`, `<name>_job_names`,
  `<name>_list_entry`, `<name>_help`, `<name>_stage_usage`.
- `deploy_check.sh` -- fast syntax/shape checks run before every deploy. See
  `deploy_check.sh.example` in this directory -- **rename it to
  `deploy_check.sh` in your real pipeline directory** (it's suffixed `.example`
  here specifically so `poll_and_deploy.sh`'s directory scan -- which looks for
  `deploy_check.sh` in every `pipelines/*/` directory, not just ones in
  `pipelines.yaml` -- never picks this template up and tries to run it during
  a real deploy).
- Your actual pipeline code + Dockerfile.

## Steps to actually add a pipeline

1. `cp -r pipelines/_template pipelines/<name>` and `mv
   pipelines/<name>/deploy_check.sh.example pipelines/<name>/deploy_check.sh`.
2. Fill in `resources.yaml`, `common/env_setup.sh`, your Dockerfile, and your
   real stage scripts (`example_stage.sbatch` is a minimal starting point).
3. Copy `_template.sh` to `cli/pipelines/<name>.sh` and implement it for real
   -- rename every `template`/`TEMPLATE` occurrence to your pipeline's name.
4. Add test commands under `.github/tests/tests.yaml` keyed by `<name>`.
5. Add one entry to the repo root's `pipelines.yaml`.

That's it -- no workflow file needs editing, CI/deploy discover everything
from step 5.
