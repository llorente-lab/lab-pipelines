#!/bin/bash
# Purpose-built reader for cli/pipelines.yaml's specific shape (a flat
# "pipelines:" list of small key/value maps) -- deliberately NOT a general
# YAML parser. Same philosophy as project_meta.yaml's grep/sed handling
# elsewhere in this repo: this is the only reader of this exact file, so it
# only needs to understand this exact shape, not arbitrary YAML nesting.
# Avoids adding a yq/pyyaml dependency (system python on Sherlock login
# nodes doesn't ship pyyaml, and yq isn't guaranteed to be installed) for a
# five-entry config file.
#
# load_pipeline_manifest <path-to-pipelines.yaml> emits one colon-delimited
# line per pipeline entry:
#   name:module:env_setup:required_env_var:sif_var
# -- callers (cli/run, cli/setup.sh) just loop over that with a plain
# `while IFS=: read -r ...`, same as before this was ever YAML.
load_pipeline_manifest() {
  local manifest="$1"
  awk '
    function flush() {
      if (name != "") {
        print name ":" module ":" env_setup ":" required_env_var ":" sif_var
      }
      name = ""; module = ""; env_setup = ""; required_env_var = ""; sif_var = ""
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]*name:/ {
      flush()
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
      name = line
      next
    }
    /^[[:space:]]*module:/ {
      line = $0; sub(/^[[:space:]]*module:[[:space:]]*/, "", line); module = line; next
    }
    /^[[:space:]]*env_setup:/ {
      line = $0; sub(/^[[:space:]]*env_setup:[[:space:]]*/, "", line); env_setup = line; next
    }
    /^[[:space:]]*required_env_var:/ {
      line = $0; sub(/^[[:space:]]*required_env_var:[[:space:]]*/, "", line); required_env_var = line; next
    }
    /^[[:space:]]*sif_var:/ {
      line = $0; sub(/^[[:space:]]*sif_var:[[:space:]]*/, "", line); sif_var = line; next
    }
    END { flush() }
  ' "$manifest"
}
