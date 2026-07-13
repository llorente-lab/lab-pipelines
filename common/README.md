# common/

Empty on purpose for now. This is where code shared by more than one
pipeline goes -- but only once a second pipeline (MoSeq, etc.) actually
needs something that currently lives inside `miniscope/`, at which point
that piece gets promoted here and both pipelines import/source it from this
location.

Nothing gets written here speculatively. Building shared abstractions before
a second real caller exists tends to guess wrong about what actually needs
to be shared, and this repo already paid for that lesson once with
`miniscope/common/reconcile_common.py` (built shared *within* Miniscope only
after the duplication between the MC and CNMF-E reconciliation scripts was
real and visible, not before).

Likely first candidates, once MoSeq exists, roughly in order of how
pipeline-agnostic they already are:

- Sherlock storage-tier-aware env resolution (currently `MINISCOPE_*`-prefixed
  in `miniscope/common/env_setup.sh`, would need genericizing)
- The `apptainer_python`/`apptainer_rclone` wrapper pattern
- The per-session `logs/` convention
- The reconciliation "discover -> filter excluded -> yield eligible" shape
  (the specific done/ready checks would stay pipeline-specific, but the
  shell around them might not)
