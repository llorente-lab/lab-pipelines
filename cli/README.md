# cli/

The execution + monitoring layer. `run` is the one command a lab member
needs to run pipelines, check on them, and find their logs -- no `cd`-ing
into the deployed tree, no remembering `sbatch` argument order or log paths.
`setup.sh` is the one-time (safely re-runnable) bootstrap for a new lab
member's shell.

## Why this is a separate top-level directory

Same reasoning as `deploy/` being separate from `miniscope/`: this layer
should never need to know deployment mechanics (it just reads through the
`current` symlink like anything else), and pipeline code should never need
to know how it gets invoked by a human. Keeping `cli/` as its own directory
makes that boundary real in the repo layout, not just a convention someone
has to remember.

## Why `run` is Miniscope-specific right now, not generic

`run miniscope motion-correction ...` hardcodes knowledge of Miniscope's two
stages directly, rather than reading a generic pipeline manifest. That's
deliberate: there's only one real pipeline built so far, and designing a
generic manifest-driven dispatcher against a single data point means
guessing what a second pipeline actually needs. When MoSeq (or anything
else) is real, look at what's duplicated between its `cli/` wiring and
Miniscope's here -- *that* duplication is what should inform a real generic
design, not speculation now. Same discipline as `common/`: shared
abstractions get extracted once they're earned by a second real caller, not
built ahead of one.

## Files

- `run` -- the user-facing command. Deployed onto `$PATH` via
  `miniscope/common/env_setup.sh` (which every lab member sources from
  `~/.bashrc`), so it updates automatically on every deploy.
- `setup.sh` -- one-time shell bootstrap for a new lab member: idempotently
  adds the `env_setup.sh` source line to `~/.bashrc`, and runs a handful of
  sanity checks (group access, container/rclone config present, etc.) with
  clear pass/fail output. Safe and useful to rerun any time, not just once
  -- there's no separate "verify" command, rerunning `setup.sh` again *is*
  the verify/fix step.
- `deploy_check.sh` -- gates deploys on both files' syntax being valid,
  same convention as every other pipeline's `deploy_check.sh`.
