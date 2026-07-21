# lab-pipelines

Monorepo for the lab's Sherlock-based analysis pipelines. One repo, one
deploy mechanism, shared conventions -- each pipeline is a directory under
`pipelines/`, discovered generically (by both the CLI and CI) via
`pipelines.yaml` at the repo root.

```
lab-pipelines/
  setup.sh                 one-time (rerunnable) shell bootstrap for a new lab member
  pipelines.yaml          single manifest: CLI wiring + CI build config, per pipeline
  deploy/
    poll_and_deploy.sh    cron-invoked GitOps-style deploy agent, generic
  cli/
    run                    the one command lab members need, see below
    manifest.sh             reads pipelines.yaml
    pipelines/<name>.sh     per-pipeline CLI functions (naming-convention based)
  common/                 code shared by 2+ pipelines (job_init, monitor_resources, apptainer wrappers)
  pipelines/
    miniscope/             CaImAn-based Miniscope calcium imaging pipeline
    moseq/                 Datta-lab moseq2 motion-sequencing pipeline
```

Adding a third pipeline: a `pipelines/<name>/` directory plus one entry in
`pipelines.yaml` (see that file's header for the checklist). No CLI or CI
edit is needed -- both discover pipelines from the manifest.

## For lab members: running pipelines

1. Sherlock account access to the `illorent` group (ask your PI/sponsor).
2. Run the bootstrap script once, by full path:

   ```
   bash $GROUP_HOME/pipelines/current/setup.sh
   ```

   Idempotent and safe to rerun any time -- there's no separate "verify"
   step.

After that, open a new shell:

```
run list
run miniscope motion-correction --mouse XXXXX --date 2025-01-01 --tp tp1
run status
run logs miniscope motion-correction --mouse XXXXXX --date 2025-01-01 --tp tp1
```

See `cli/README.md` for the full command reference. `run` is a generic,
manifest-driven dispatcher with no per-pipeline code inside it -- just a
thin wrapper around the same `.sbatch` files anyone can still call
directly.

## Deployment model

Sherlock's login nodes can't be reached from the internet, so this is
pull-based, GitOps-style: a job on a schedule (`scrontab`, not a real
crontab -- Sherlock disables those on login nodes) checks whether
`origin/main` moved, and deploys if so.

The deploy tree lives under `/home/groups/illorent/pipelines` (shared, backed up,
lab-wide), not any one person's home directory.

```
$GROUP_HOME/pipelines/
  _repo/            persistent clone, `git fetch` happens here
  releases/<sha>/   one git worktree per deployed commit
  current -> releases/<sha>/     every pipeline's scripts resolve their root through this symlink
  deploy/poll_and_deploy.sh      checked out once, manually, outside the release cycle
  logs/deploy/deploy.log         deploy history
```

Each commit gets its own `git worktree` under `releases/`. Before
promotion, the deploy agent runs each pipeline's `deploy_check.sh` (if one
exists) and only flips `current` if every check passes -- `ln -sfn` swaps
it atomically, so a bad commit never gets promoted and a mid-run job never
sees a half-old, half-new tree.

`poll_and_deploy.sh` prepends known-good module bin directories onto
`PATH` directly (Sherlock's default `git`/`python3` are too old for
`git worktree`/`from __future__ import annotations`, and `module load`
isn't reliable inside a `scrontab` job) -- see `GIT_MODULE_BIN`/
`PYTHON_MODULE_BIN` near the top of that file if Sherlock's software
changes.

### One-time setup on Sherlock

```
mkdir -p $GROUP_HOME/pipelines
git clone --branch main <this repo's URL> $GROUP_HOME/pipelines/_repo
SHA=$(git -C $GROUP_HOME/pipelines/_repo rev-parse HEAD)
git -C $GROUP_HOME/pipelines/_repo worktree add $GROUP_HOME/pipelines/releases/$SHA HEAD
ln -sfn $GROUP_HOME/pipelines/releases/$SHA $GROUP_HOME/pipelines/current
```

Then, once, copy `deploy/poll_and_deploy.sh` out to a stable path (outside
the release cycle) and install the schedule:

```
mkdir -p $GROUP_HOME/pipelines/deploy
cp $GROUP_HOME/pipelines/current/deploy/poll_and_deploy.sh $GROUP_HOME/pipelines/deploy/poll_and_deploy.sh
scrontab -e
# paste in deploy/lab-pipelines.scrontab (fix the hardcoded path if
# $GROUP_HOME differs from /home/groups/illorent)
```

Any lab member's account can own the `scrontab` entry -- everything it
reads/writes lives under the shared `$GROUP_HOME`, so the effect is
lab-wide regardless of whose account runs it.

`poll_and_deploy.sh` lives outside the release cycle on purpose: a
`git pull` into `_repo` alone does not update the scheduled copy. Any
future change to that file needs a manual `cp` from `_repo/deploy/` (not
`current/`, which only advances after a successful deploy).

## Adding a new pipeline

1. `mkdir pipelines/<name>` with a `Dockerfile`, `common/env_setup.sh`
   (source `common/job_template.sh`/`common/apptainer_helpers.sh` from the
   repo root), `resources.yaml` (same schema as `pipelines/moseq/resources.yaml`),
   and stage `.sbatch` scripts -- internal shape doesn't need to mirror
   Miniscope's layout.
2. Optionally a `deploy_check.sh` at the top of `pipelines/<name>/` (fast
   checks only, runs on the login node every deploy) -- discovered
   automatically, no edit needed elsewhere.
3. Only reach into `common/` for something already duplicated between two
   real pipelines, not preemptively -- see `common/README.md`.
4. Add `cli/pipelines/<name>.sh` implementing `cmd_<name>`, `cmd_logs_<name>`,
   `<name>_job_names`, `<name>_list_entry`, `<name>_help`, `<name>_stage_usage`.
5. Add a `<name>:` key to `.github/tests/tests.yaml` with the smoke-test
   commands CI should run inside the built image.
6. Add one entry to `pipelines.yaml` -- this is the only registration step;
   both the CLI and every CI workflow discover pipelines from it.

