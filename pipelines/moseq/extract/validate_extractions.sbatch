#!/bin/bash
# Submitted by submit_moseq.submit_extraction() with --dependency=afterany so it runs
# after all array tasks finish (pass or fail).
#SBATCH --job-name=moseq-validate-extractions
#SBATCH --partition=normal
#SBATCH --time=0:30:00

set -euo pipefail
source "${GROUP_HOME:-$HOME}/pipelines/current/pipelines/moseq/common/env_setup.sh"
source "$REPO_COMMON_DIR/job_template.sh"

PROJECT_ROOT="${1-}"
job_init "validate_extractions" "$PROJECT_ROOT"

echo "------------------------------------------------------------------"
echo ">>> VALIDATE EXTRACTIONS START: $(date)"
echo "Project => $PROJECT_ROOT"
echo "------------------------------------------------------------------"

apptainer_python -c "
import sys
sys.path.insert(0, '$MOSEQ_COMMON_DIR')
from moseq2_app.gui.wrappers import validate_extractions_wrapper
validate_extractions_wrapper('$PROJECT_ROOT')
"

echo "------------------------------------------------------------------"
echo ">>> VALIDATE EXTRACTIONS END: $(date)"
echo "------------------------------------------------------------------"
echo "==== JOB END: $(date) ===="
