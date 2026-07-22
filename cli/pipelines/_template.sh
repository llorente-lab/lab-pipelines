#!/bin/bash
# Reference cli/pipelines/<name>.sh -- lives here (not under
# pipelines/_template/) because this is where `run` actually expects a
# pipeline's dispatch module to live. Not referenced by pipelines.yaml, so
# `run` never sources this file -- fully inert until you copy it.
#
# To use: copy this file to cli/pipelines/<name>.sh and replace every
# "template"/"TEMPLATE" with your pipeline's real name (matching whatever
# "name"/"module" you put in the repo root's pipelines.yaml).
#
# The six functions below are the entire contract `run` needs from a
# pipeline module -- see cli/run for exactly how/when each is called.

cmd_template() {
  local stage="${1-}"; shift || true

  if [ "$stage" = "help" ] || [ "$stage" = "--help" ] || [ "$stage" = "-h" ]; then
    template_help
    return 0
  fi
  if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
    template_stage_usage "$stage"
    return $?
  fi

  # cli/run already checked $TEMPLATE_PROJECTS_BASE (or whatever
  # required_env_var you declared in pipelines.yaml) is set before calling
  # this function at all -- see require_pipeline_env in cli/run.

  local exclusive="" cores="" mem="" walltime=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclusive) exclusive="1"; shift ;;
      --cores)     cores="$2"; shift 2 ;;
      --mem)       mem="$2"; shift 2 ;;
      --time)      walltime="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  case "$stage" in
    example-stage)
      local scope_dir="$TEMPLATE_PROJECTS_BASE/${1:?run template example-stage <name>}"
      _set_resource_flags template example-stage
      [ -n "$exclusive" ] && _force_exclusive
      _apply_resource_overrides "$cores" "$mem" "$walltime"
      _sbatch_submit "$scope_dir/status" example-stage \
        ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} \
        "$TEMPLATE_ROOT_DIR/example_stage/example_stage.sbatch" "$scope_dir"
      ;;
    dashboard)
      local scope_dir="$TEMPLATE_PROJECTS_BASE/${1-}"
      python3 "$REPO_COMMON_DIR/dashboard.py" "$scope_dir"
      ;;
    "")
      echo "run: missing template stage -- try 'example-stage' or 'dashboard'" >&2
      exit 1
      ;;
    *)
      echo "run: unknown template stage '$stage'" >&2
      exit 1
      ;;
  esac
}

# Stage names must match the log-file prefix your .sbatch script's
# job_init/start_resource_monitor calls use -- keep hyphens/underscores
# consistent with what you picked in resources.yaml and the .sbatch itself.
cmd_logs_template() {
  local stage="${1-}"; shift || true
  local name="${1-}"; shift || true
  if [ -z "$stage" ] || [ -z "$name" ]; then
    echo "run logs template: usage: run logs template <stage> <name>" >&2
    exit 1
  fi
  local scope_dir="$TEMPLATE_PROJECTS_BASE/$name"
  local log_dir="$scope_dir/slurm_logs"
  local latest
  latest="$(ls -t "$log_dir"/${stage}-*.out 2>/dev/null | head -n1 || true)"
  if [ -z "$latest" ]; then
    echo "run logs template: no ${stage} log found under $log_dir yet" >&2
    exit 1
  fi
  echo "run logs: tailing $latest (Ctrl-C to stop)"
  tail -F "$latest"
}

template_job_names() {
  echo "template-example-stage"
}

template_list_entry() {
  cat <<'EOF'
template
  example-stage <name>   run template example-stage <name> [--exclusive|--cores N|--mem MEM|--time T]
  dashboard <name>       run template dashboard <name>
EOF
}

template_stage_usage() {
  case "$1" in
    example-stage) echo "usage: run template example-stage <name> [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    dashboard)     echo "usage: run template dashboard <name>" ;;
    "")
      echo "usage: run template <stage> --help -- but no stage was given. Try 'run template help' for the full list." >&2
      return 1
      ;;
    *)
      echo "run template: unknown stage '$1' -- run 'run template help' for the full list" >&2
      return 1
      ;;
  esac
}

template_help() {
  cat <<'EOF'
  run template example-stage <name> [--exclusive] [--cores N] [--mem MEM] [--time T]
  run template dashboard <name>
  run logs template <stage> <name>

Replace this whole help block with real documentation for your pipeline's
actual stages once you've filled them in -- see cli/pipelines/moseq.sh or
cli/pipelines/miniscope.sh for the level of detail worth aiming for
(what each flag does, what's chained vs. manual, common gotchas).
EOF
}
