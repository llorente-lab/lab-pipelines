# moseq/

Placeholder. Not started. Reserving the top-level directory now so that when
this pipeline actually gets built, it slots into the same monorepo/deploy
pattern as `miniscope/` from day one, instead of Miniscope needing a
disruptive restructure later to make room for it (which is exactly what just
happened moving Miniscope's originally-flat `scripts/` layout into
`miniscope/`).

When this becomes real, it should get its own `deploy_check.sh` at this
level (see `miniscope/deploy_check.sh` for the pattern `deploy/
poll_and_deploy.sh` looks for), and anything it turns out to share with
Miniscope should get promoted into `../common/`, not duplicated.
