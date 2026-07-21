#!/bin/bash
# Sanity check run by deploy/poll_and_deploy.sh before promoting a new commit
# to `current`. Same fast, dependency-light philosophy as
# miniscope/deploy_check.sh -- no Apptainer, no Sherlock resources, just
# syntax/shape checks that catch typos before they reach `current`.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bash -n common/env_setup.sh
bash -n jupyter_kernel/moseq_kernel_wrapper.sh

# kernel.json must live at kernels/<name>/kernel.json under JUPYTER_PATH,
# not directly in jupyter_kernel/ -- jupyter silently ignores it otherwise
# (no error, just doesn't show up in `jupyter kernelspec list`). This check
# would have caught that bug the first time.
python3 -c "import json; json.load(open('jupyter_kernel/kernels/moseq2-apptainer/kernel.json'))"

# reconcile_moseq_progress.py imports moseq2_app (needs the container), so
# it's deliberately NOT checked here -- same reasoning as
# miniscope/deploy_check.sh excluding test_path_resolution.py. Only the
# pure-stdlib extraction-status check runs as part of the fast deploy gate.
python3 tests/test_reconcile_moseq_extraction.py

# submit_moseq.py also only imports stdlib (subprocess/re/pathlib) +
# reconcile_moseq_extraction, no moseq2 packages -- fully testable here too.
python3 tests/test_submit_moseq.py

for f in extract/extract.sbatch extract/aggregate.sbatch \
         pca/pca_fit.sbatch pca/pca_apply.sbatch pca/compute_changepoints.sbatch \
         model/kappa_scan.sbatch model/learn_model.sbatch \
         ../../common/job_template.sh ../../common/monitor_resources.sh; do
  bash -n "$f"
done

# compute_npcs.py's file-I/O parts (h5py, ruamel.yaml) need the container,
# but its actual selection math (npcs_for_variance) is pure numpy and
# fully unit-tested here, no container needed.
python3 tests/test_compute_npcs.py

# select_best_kappa.py needs moseq2_viz (container-only), so only
# syntax-checked here, same treatment as reconcile_moseq_progress.py above.
python3 -c "import ast; ast.parse(open('model/select_best_kappa.py').read())"
