#!/bin/bash
# Generator for the apptainer_python/apptainer_rclone/apptainer_exec wrapper
# functions every pipeline's env_setup.sh has hand-copied so far (moseq and
# miniscope currently define near-identical versions of these by hand).
# New pipelines should call this instead of copy-pasting the wrappers.
#
# Usage, in a pipeline's env_setup.sh, after that pipeline's own SIF/
# RCLONE_CONFIG vars are exported:
#
#   # shellcheck disable=SC1091
#   source "$REPO_COMMON_DIR/apptainer_helpers.sh"
#   define_apptainer_wrappers MY_SIF_VAR
#
# define_apptainer_wrappers <sif-var-name> defines, in the calling shell:
#   apptainer_python <args...>   -- runs `python <args...>` in the container
#   apptainer_rclone <args...>   -- runs `rclone <args...>` in the container
#   apptainer_exec <args...>     -- runs an arbitrary command in the container
#                                    (for pipelines with installed console
#                                    entry points, e.g. moseq2-extract, that
#                                    aren't plain python scripts)
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
