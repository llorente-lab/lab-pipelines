#!/bin/bash
# Defines apptainer_python/apptainer_rclone/apptainer_exec wrappers so new
# pipelines don't have to hand-copy them (moseq and miniscope currently do).
#
# Usage, in a pipeline's env_setup.sh, after its SIF/RCLONE_CONFIG vars are
# exported:
#
#   # shellcheck disable=SC1091
#   source "$REPO_COMMON_DIR/apptainer_helpers.sh"
#   define_apptainer_wrappers MY_SIF_VAR
#
# apptainer_exec is for anything with an installed console entry point
# (e.g. moseq2-extract) rather than a plain python script.
define_apptainer_wrappers() {
  local sif_var="$1"
  if [ -z "$sif_var" ]; then
    echo "define_apptainer_wrappers: usage: define_apptainer_wrappers <SIF_VAR_NAME>" >&2
    return 1
  fi

  # shellcheck disable=SC2139
  eval "
    apptainer_python() {
      apptainer exec --env \"RCLONE_CONFIG=\${RCLONE_CONFIG}\" --env \"PYTHONNOUSERSITE=1\" \\
        \"\${$sif_var}\" python \"\$@\"
    }
    apptainer_rclone() {
      apptainer exec --env \"RCLONE_CONFIG=\${RCLONE_CONFIG}\" \"\${$sif_var}\" rclone \"\$@\"
    }
    apptainer_exec() {
      apptainer exec --env \"RCLONE_CONFIG=\${RCLONE_CONFIG}\" --env \"PYTHONNOUSERSITE=1\" \\
        \"\${$sif_var}\" \"\$@\"
    }
  "
}
