# lab-pipelines

Monorepo for the lab's Sherlock-based analysis pipelines. One repo, one
deploy mechanism, shared low-level conventions -- each pipeline is a
top-level directory.

```
lab-pipelines/
  deploy/
    poll_and_deploy.sh    # cron-invoked GitOps-style deploy agent, generic
  cli/
    run                    # the one command lab members need, see below
    setup.sh                # one-time (rerunnable) shell bootstrap
  common/                 # code shared by 2+ pipelines (empty until MoSeq needs it)
  miniscope/               # CaImAn-based Miniscope calcium imaging pipeline
  moseq/                    # placeholder, not started
```

## Deployment model

Sherlock's login nodes can't be reached from the internet, so this can't be
push-based (no webhook can ever land). Instead it's pull-based, the same
idea GitOps tools like Flux use: a scheduled job periodically checks whether
`origin/main` has moved, and if so, deploys. It runs via `scrontab` (Slurm's
own cron), not a real crontab -- Sherlock disables plain user crontabs on
login nodes.

The deploy tree lives under `$GROUP_HOME/pipelines`, not any one person's
`$HOME`. `$GROUP_HOME` is shared across the whole lab's group account,
backed up, and never purged -- the right tier for code every lab member's
jobs depend on, not something only whoever set it up can use.

```
$GROUP_HOME/pipelines/
  _repo/            persistent clone, `git fetch` happens here
  releases/<sha>/   one git worktree per deployed commit
  current -> releases/<sha>/     <- every pipeline's scripts resolve their
                                     root through this symlink
  deploy/poll_and_deploy.sh      <- checked out once, manually; lives OUTSIDE
                                     the release cycle so a broken commit can
                                     never break the thing that deploys it
  logs/deploy/deploy.log         <- deploy history, visible to the whole group
```

Every commit gets its own `git worktree` under `releases/`, cheap and
isolated. Before promotion, the deploy agent runs each pipeline's
`<pipeline>/deploy_check.sh`, if one exists, and only flips the `current`
symlink if every check that exists passes. `ln -sfn` swaps the symlink as a
single atomic operation, so a job that's mid-run when a new commit lands
never sees a half-old, half-new tree, and a bad commit simply never gets
promoted (the next poll retries once a fix is pushed).

Sherlock's default `git`/`python3` on `$PATH` are old enough to be missing
things this repo depends on (`git worktree`/`-C`, `from __future__ import
annotations`), and `module load` turned out not to reliably activate inside
a `scrontab`-launched batch job (Lmod's init script doesn't get sourced the
way it does in an interactive shell). `poll_and_deploy.sh` works around this
by prepending known-good module bin/ directories onto `PATH` directly,
unconditionally, rather than depending on `module load` succeeding --
see `GIT_MODULE_BIN`/`PYTHON_MODULE_BIN` near the top of that file if a
Sherlock software update ever changes those paths.

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
# paste in the contents of deploy/lab-pipelines.scrontab (fix the
# hardcoded path there if $GROUP_HOME differs from /home/groups/illorent)
```

Any one lab member's account can own the `scrontab` entry -- it's inherently
per-user, but everything it reads from and writes to lives under the shared
`$GROUP_HOME`, so the effect is lab-wide regardless of whose account runs it.

Remember `deploy/poll_and_deploy.sh` lives OUTSIDE the release cycle on
purpose: a `git pull` into `_repo` alone does NOT update the copy that's
actually scheduled. Any future change to that specific file needs a manual
`cp` from `$GROUP_HOME/pipelines/_repo/deploy/poll_and_deploy.sh` (not from
`current/`, which only advances after a successful deploy) to take effect.

## For lab members: running pipelines

Nobody needs to clone this repo, touch `$GROUP_HOME/pipelines` directly, or
`cd` into the deployed tree just to run something -- that's the whole point
of the `cli/` layer. Two things, once, and neither involves git:

1. Sherlock account access to the `illorent` group (an actual account
   provisioning step -- ask your PI/sponsor -- not something any script can
   grant, since it's what makes `$GROUP_HOME` even readable).
2. Run the bootstrap script once, by full path since nothing's on `$PATH`
   yet before this:

   ```
   bash $GROUP_HOME/pipelines/current/cli/setup.sh
   ```

   This is idempotent and safe to rerun any time (e.g. to re-check your
   setup later) -- there's no separate "verify" step. It adds the one line
   your shell needs to `~/.bashrc` and reports pass/fail on a handful of
   sanity checks.

After that, open a new shell and everything is just:

```
run list
run miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1
run status
run logs miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1
```

See `cli/README.md` for the full command reference and why `run` is
Miniscope-specific for now rather than a generic multi-pipeline dispatcher.
Nothing here is hidden or gatekept -- `run` is a thin wrapper around the
same `.sbatch` files anyone can still call directly if they want to see
exactly what's happening underneath.

## Adding a new pipeline

1. New top-level directory, e.g. `moseq/`.
2. Its own `common/`, stage scripts, `.sbatch` files -- whatever shape fits
   that pipeline, doesn't need to mirror Miniscope's internal layout exactly.
3. A `deploy_check.sh` at the top of the directory if you want the deploy
   agent to gate on it (fast, dependency-light checks only -- it runs on the
   login node on every deploy, not inside the container).
4. Only reach into `common/` for something already duplicated between two
   real pipelines, not preemptively.
5. Add its stages to `cli/run` by hand (a new `cmd_moseq()`-style case,
   following `cmd_miniscope()`). This is a deliberately manual step right
   now, not config -- see `cli/README.md` for why `run` isn't a generic
   manifest-driven dispatcher yet, and what would justify making it one.

## Why a monorepo

Every pipeline here targets the same cluster, the same storage conventions,
the same container/rclone auth patterns, and the same deploy mechanism.
Splitting into separate repos would mean N copies of that boilerplate and N
places for the deploy agent to drift. See `common/README.md` for more on
what does and doesn't belong there.
