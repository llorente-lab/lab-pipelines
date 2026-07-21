# cli/

The execution + monitoring layer. `run` is the one command a lab member
needs to run pipelines, check on them, find their logs, and move data
between Drive and scratch -- no `cd`-ing into the deployed tree, no
remembering `sbatch` argument order, log paths, or raw `rclone` invocations.
`setup.sh` is the one-time (safely re-runnable) bootstrap for a new lab
member's shell.

`run sync <src> <dst> [rclone flags...]` is a deliberately thin,
unopinionated wrapper around `rclone copy` (via `apptainer_rclone`, since
plain `rclone` isn't on Sherlock's compute node `$PATH`) -- no default
excludes, no assumed direction, either path can be a `gdrive:` remote or a
local scratch path. This is different from `sync.sh` (used internally
after every MC/CNMF-E run), which bakes in `--exclude '*.mmap' --exclude
'*.avi'` for that specific automatic case; `run sync` leaves the safety net
opt-in.

## `run` is manifest-driven, not per-pipeline

`run` doesn't hardcode any pipeline's stages. It reads `pipelines.yaml`
(repo root) via `manifest.sh`, sources every listed pipeline's
`env_setup.sh` and `pipelines/<name>.sh` module, and dispatches by name
purely through naming convention (`cmd_<name>`, `cmd_logs_<name>`,
`<name>_job_names`, `<name>_list_entry`, `<name>_help`, `<name>_stage_usage`
-- see `pipelines/moseq.sh` or `pipelines/miniscope.sh` for the concrete
shape). Adding a pipeline means one manifest entry and one new
`pipelines/<name>.sh` file -- `run` itself never changes.

## Files

- `run` -- the user-facing command. Deployed onto `$PATH` via every
  pipeline's `env_setup.sh`, so it updates automatically on every deploy.
- `setup.sh` -- one-time shell bootstrap for a new lab member: idempotently
  adds every pipeline's `env_setup.sh` source line to `~/.bashrc` and runs
  sanity checks (group access, container/rclone config present) with
  pass/fail output. Safe to rerun any time -- rerunning it IS the
  verify/fix step.
- `manifest.sh` -- the `pipelines.yaml` reader shared by `run` and
  `setup.sh` (and read directly by the CI workflows).
- `deploy_check.sh` -- gates deploys on `run`/`setup.sh`/`manifest.sh`
  syntax and `pipelines.yaml` parsing being valid.
