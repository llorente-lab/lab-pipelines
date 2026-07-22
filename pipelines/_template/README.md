# Pipeline template

A reference scaffold for adding a new pipeline to this repo. Not referenced
by `pipelines.yaml`, so it's inert -- nothing discovers or runs it on its
own. Use `run pipeline-new <name>` to copy and rename it automatically, or
copy it by hand.

## Already generic -- don't reimplement these

- **Resource flags** (`--partition`/`--exclusive`/`--cpus-per-task`/`--mem`/`--time`)
  come from `cli/estimate_resources.py`, driven by your `resources.yaml`.
- **Job history and status** come from sourcing `common/job_template.sh` in
  your `.sbatch` scripts (`job_init "<stage>" "$SOME_ROOT"` at the top).
  Writes `status/<stage>.json` and `status/history.jsonl` with no extra code.
- **The dashboard** comes from `common/dashboard.py`, as long as each
  submission is recorded to `status/jobs.jsonl` (`_sbatch_submit` in
  `cli/resources.sh` for bash, or see `pipelines/moseq/common/submit_moseq.py`
  for the Python equivalent).
- **Syncing** (Drive <-> Sherlock) should go through `run sync <src> <dst>`
  rather than a pipeline-specific rclone call. See
  `pipelines/miniscope/common/sync.sh` for a thin wrapper example.
- **CI and deploy discovery** come from one entry in the repo root's
  `pipelines.yaml`. No workflow file needs editing.

## Still hand-written

- `resources.yaml` -- one stage per compute job.
- `common/env_setup.sh` -- container path, puts `run` on `PATH`, any
  `apptainer_*` helpers your stages need.
- `cli/pipelines/<name>.sh` -- see `_template.sh` next to this README for
  the functions `run` expects: `cmd_<name>`, `cmd_logs_<name>`,
  `<name>_job_names`, `<name>_list_entry`, `<name>_help`,
  `<name>_stage_usage`.
- `deploy_check.sh` -- fast syntax checks run before every deploy. Kept as
  `deploy_check.sh.example` here on purpose: `poll_and_deploy.sh` runs any
  file literally named `deploy_check.sh` under `pipelines/*/`, regardless of
  `pipelines.yaml`, so only rename it once inside your real pipeline
  directory.
- Your actual pipeline code and Dockerfile.

## Adding a pipeline

1. `run pipeline-new <name>` (scaffolds `pipelines/<name>/` and
   `cli/pipelines/<name>.sh`, already renamed).
2. Fill in `resources.yaml`, `common/env_setup.sh`, the Dockerfile, and your
   real stage scripts.
3. Implement `cli/pipelines/<name>.sh` for real.
4. Add test commands under `.github/tests/tests.yaml` keyed by `<name>`.
5. Add one entry to the repo root's `pipelines.yaml`.

That's it -- no workflow file needs editing, CI and deploy discover
everything from step 5.
