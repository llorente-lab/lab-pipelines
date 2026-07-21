#!/bin/bash
# Not a general YAML parser -- purpose-built for pipelines.yaml's flat structure,
# avoiding a yq/pyyaml dependency.
load_pipeline_manifest() {
  local manifest="$1"
  awk '
    function flush() {
      if (name != "") {
        print name ":" module ":" env_setup ":" required_env_var ":" sif_var ":" resources_yaml
      }
      name = ""; module = ""; env_setup = ""; required_env_var = ""; sif_var = ""; resources_yaml = ""
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
    /^[[:space:]]*resources_yaml:/ {
      line = $0; sub(/^[[:space:]]*resources_yaml:[[:space:]]*/, "", line); resources_yaml = line; next
    }
    END { flush() }
  ' "$manifest"
}
