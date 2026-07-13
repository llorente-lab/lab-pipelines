# lab-pipelines

Monorepo for the lab's Sherlock-based analysis pipelines. One repo, one
deploy mechanism, shared low-level conventions -- each pipeline is a
top-level directory.

```
lab-pipelines/
  deploy/
    poll_and_deploy.sh    # cron-invoked GitOps-style deploy agent, generic
  common/                 # code shared by 2+ pipelines (empty until MoSeq needs it)
  miniscope/               # CaImAn-based Miniscope calcium imaging pipeline
  moseq/                    # placeholder, not started
```

## Deployment model

Sherlock's login nodes can't be reached from the internet, so this can't be
push-based (no webhook can ever land). Instead it's pull-based, the same
idea GitOps tools like Flux use: a cron job on the login node periodically
checks whether `origin/main` has moved, and if so, deploys.

```
~/pipelines/
  _repo/            persistent clone, `git fetch` happens here
  releases/<sha>/   one git worktree per deployed commit
  current -> releases/<sha>/     <- every pipeline's scripts resolve their
                                     root through this symlink
  deploy/poll_and_deploy.sh      <- checked out once, manually; lives OUTSIDE
                                     the release cycle so a broken commit can
                                     never break the thing that deploys it
```

Every commit gets its own `git worktree` under `releases/`, cheap and
isolated. Before promotion, the deploy agent runs each pipeline's
`<pipeline>/deploy_check.sh`, if one exists, and only flips the `current`
symlink if every check that exists passes. `ln -sfn` swaps the symlink as a
single atomic operation, so a job that's mid-run when a new commit lands
never sees a half-old, half-new tree, and a bad commit simply never gets
promoted (the next poll retries once a fix is pushed).

### One-time setup on Sherlock

```
mkdir -p ~/pipelines
git clone --branch main <this repo's URL> ~/pipelines/_repo
git -C ~/pipelines/_repo worktree add ~/pipelines/releases/$(git -C ~/pipelines/_repo rev-parse HEAD) HEAD
ln -sfn ~/pipelines/releases/$(git -C ~/pipelines/_repo rev-parse HEAD) ~/pipelines/current
```

Then, once, copy `deploy/poll_and_deploy.sh` out to a stable path and add it
to crontab:

```
cp ~/pipelines/current/deploy/poll_and_deploy.sh ~/pipelines/deploy/poll_and_deploy.sh
crontab -e
# add:
*/5 * * * * /home/users/<you>/pipelines/deploy/poll_and_deploy.sh >> /scratch/users/<you>/logs/deploy/cron.log 2>&1
```

And point every shell at the deployed tree instead of a fixed path, in
`~/.bashrc`:

```
source ~/pipelines/current/miniscope/common/env_setup.sh
```

## Adding a new pipeline

1. New top-level directory, e.g. `moseq/`.
2. Its own `common/`, stage scripts, `.sbatch` files -- whatever shape fits
   that pipeline, doesn't need to mirror Miniscope's internal layout exactly.
3. A `deploy_check.sh` at the top of the directory if you want the deploy
   agent to gate on it (fast, dependency-light checks only -- it runs on the
   login node on every deploy, not inside the container).
4. Only reach into `common/` for something already duplicated between two
   real pipelines, not preemptively.

## Why a monorepo

Every pipeline here targets the same cluster, the same storage conventions,
the same container/rclone auth patterns, and the same deploy mechanism.
Splitting into separate repos would mean N copies of that boilerplate and N
places for the deploy agent to drift. See `common/README.md` for more on
what does and doesn't belong there.
