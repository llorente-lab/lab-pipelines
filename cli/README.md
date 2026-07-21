# cli/

The execution + monitoring layer. `run` is the one command a lab member
needs to run pipelines, check on them, find their logs, and move data
between Drive and scratch -- no `cd`-ing into the deployed tree, no
remembering `sbatch` argument order, log paths, or raw `rclone` invocations.
`setup.sh` is the one-time (safely re-runnable) bootstrap for a new lab
member's shell.

`run sync <src> <dst> [rclone flags...]` deserves a specific callout: it's a
deliberately thin, unopinionated wrapper around `rclone copy` (via
`apptainer_rclone`, since plain `rclone` isn't on Sherlock's compute node
`$PATH`). No default excludes, no assumed direction -- either path can be a
`gdrive:` remote or a local scratch path, same as `cp`. This is different
from `sync.sh` (used internally after every MC/CNMF-E run), which bakes in
`--exclude '*.mmap' --exclude '*.avi'` because that specific automatic case
always wants them; `run sync` is the general-purpose escape hatch for
everything else, so the safety net is opt-in per call, not forced on you.

## Why this is a separate top-level directory

Same reasoning as `deploy/` being separate from `pipelines/`: this layer
should never need to know deployment mechanics (it just reads through the
`current` symlink like anything else), and pipeline code should never need
to know how it gets invoked by a human. Keeping `cli/` as its own directory
makes that boundary real in the repo layout, not just a convention someone
has to remember.

## `run` is manifest-driven, not per-pipeline

`run` doesn't hardcode any pipeline's stages. It reads `pipelines.yaml`
(repo root) via `manifest.sh`, sources every listed pipeline's
`env_setup.sh` and `pipelines/<name>.sh` module, and dispatches by name
purely through the naming convention (`cmd_<name>`, `cmd_logs_<name>`,
`<name>_job_names`, `<name>_list_entry`, `<name>_help`, `<name>_stage_usage`
-- see `pipelines/moseq.sh` or `pipelines/miniscope.sh` for the concrete
shape). Adding a pipeline means adding one manifest entry and one new
`pipelines/<name>.sh` file -- `run` itself never needs to change. This
design was earned, not speculated: it only became generic once Moseq was
real and the duplication between its `cli/` wiring and Miniscope's was
visible, same discipline as `common/` (see that directory's own README).

## Files

- `run` -- the user-facing command. Deployed onto `$PATH` via every
  pipeline's `env_setup.sh` (each of which every lab member sources from
  `~/.bashrc`), so it updates automatically on every deploy.
- `setup.sh` -- one-time shell bootstrap for a new lab member: idempotently
  adds every pipeline's `env_setup.sh` source line to `~/.bashrc` (driven
  by the same manifest `run` uses), and runs a handful of sanity checks
  (group access, container/rclone config present, etc.) with clear
  pass/fail output. Safe and useful to rerun any time, not just once --
  there's no separate "verify" command, rerunning `setup.sh` again *is*
  the verify/fix step.
- `manifest.sh` -- the purpose-built `pipelines.yaml` reader shared by
  `run` and `setup.sh` (and read directly by the CI workflows too).
- `deploy_check.sh` -- gates deploys on `run`/`setup.sh`/`manifest.sh`
  syntax and `pipelines.yaml` parsing being valid, same convention as
  every pipeline's own `deploy_check.sh`.
