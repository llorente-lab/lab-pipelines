#!/bin/bash
# Moseq pipeline wiring for `run` (see cli/run, pipelines.yaml).
# Sourced by cli/run, not executed directly -- defines cmd_moseq,
# cmd_logs_moseq, moseq_job_names, moseq_list_entry, moseq_help (no
# cmd_queue_moseq: the dry-run status check lives at
# `run moseq check-progress <name>`, a subcommand of cmd_moseq itself,
# since it needs a project name rather than miniscope's --mouse-style
# filters -- structurally different shape, so it doesn't fit the generic
# `run queue <pipeline>` convention).

MOSEQ_PYTHON_MODULE_BIN="/share/software/user/open/python/3.9.0/bin"
[ -d "$MOSEQ_PYTHON_MODULE_BIN" ] && PATH="$MOSEQ_PYTHON_MODULE_BIN:$PATH"

# Parses --exclusive/--cores/--mem/--time out of "$@" -- common resource
# overrides available on every stage, see submit_moseq.py's _resource_flags
# docstring for what each one actually does. Sets:
#   MOSEQ_EXCLUSIVE   Python bool literal ("True"/"False")
#   MOSEQ_CORES_PY    bare int literal or "None", ready to splice
#   MOSEQ_MEM_PY      bare int literal or "None", ready to splice
#   MOSEQ_TIME_PY     quoted string literal or "None", ready to splice
#   MOSEQ_REMAINING_ARGS   array of anything NOT recognized as one of the
#                          four flags above -- NOT an error by itself, since
#                          kappa-scan/learn-model have their own additional
#                          flags to check this against; a stage with no
#                          flags of its own should error if this is non-empty.
_moseq_parse_resource_flags() {
  local exclusive="False" cores="" mem="" time=""
  MOSEQ_REMAINING_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclusive) exclusive="True"; shift ;;
      --cores)     cores="$2"; shift 2 ;;
      --mem)       mem="$2"; shift 2 ;;
      --time)      time="$2"; shift 2 ;;
      *) MOSEQ_REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
  MOSEQ_EXCLUSIVE="$exclusive"
  MOSEQ_CORES_PY="${cores:-None}"
  MOSEQ_MEM_PY="${mem:-None}"
  MOSEQ_TIME_PY="None"
  [ -n "$time" ] && MOSEQ_TIME_PY="'$time'"
}

moseq_project_dir() {
  echo "$MOSEQ_PROJECTS_BASE/$1"
}

# Project names become directory names and get embedded in a yaml file, so
# keep them boring: letters, digits, underscore, hyphen only. Rejects
# anything that could break path handling or look like a yaml value needing
# escaping (spaces, colons, quotes, slashes).
moseq_validate_name() {
  case "$1" in
    ""|*[!A-Za-z0-9_-]*)
      echo "run moseq: invalid project name '$1' -- use only letters, digits, underscore, hyphen" >&2
      exit 1
      ;;
  esac
}

# Reads one "field: value" line out of a project_meta.yaml. Deliberately
# not a real yaml parser -- project_meta.yaml is only ever written by
# moseq_write_meta below with known-simple values (validated project names,
# absolute paths, rclone remote paths), so a grep/sed line match is enough
# and avoids needing a yaml library on the host (system python here is old
# and doesn't ship pyyaml).
moseq_read_meta_field() {
  local file="$1" field="$2"
  grep "^${field}:" "$file" 2>/dev/null | head -n1 | sed "s/^${field}: *//"
}

moseq_write_meta() {
  local project_dir="$1" name="$2" source="$3"
  cat > "$project_dir/project_meta.yaml" <<EOF
name: $name
sherlock_path: $project_dir
gdrive_source: $source
created: $(date -Is)
EOF
}

# Resolves <name> to its project directory and fails loudly if it doesn't
# exist -- every compute-stage subcommand and `run logs moseq` need this
# same check, so it's factored out rather than repeated per-stage.
moseq_require_project() {
  local name="$1"
  moseq_validate_name "$name"
  local project_dir
  project_dir="$(moseq_project_dir "$name")"
  if [ ! -d "$project_dir" ]; then
    echo "run moseq: project '$name' doesn't exist at $project_dir -- did you mean 'run moseq init $name'?" >&2
    exit 1
  fi
  echo "$project_dir"
}

# submit_moseq.py's functions all live on the host, imported via PYTHONPATH
# rather than `cd`-ing into common/ first -- cd-ing would silently change
# the calling shell's working directory out from under the user, which
# `run` should never do. Every compute-stage subcommand below goes through
# this so PYTHONPATH is set exactly once, consistently.
moseq_python() {
  PYTHONPATH="$MOSEQ_COMMON_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 "$@"
}

cmd_moseq() {
  local stage="${1-}"; shift || true

  # `run moseq help` / `run moseq --help` / `run moseq -h` -- full command
  # reference, same text `run --help` shows for moseq. Checked before the
  # env-setup gate below on purpose: you shouldn't need a working
  # environment just to read the help.
  if [ "$stage" = "help" ] || [ "$stage" = "--help" ] || [ "$stage" = "-h" ]; then
    moseq_help
    return 0
  fi
  # `run moseq <stage> --help` -- one-line usage for that specific stage,
  # instead of having to grep the full `moseq_help` text or dig through
  # this file to find a stage's actual arguments.
  if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
    moseq_stage_usage "$stage"
    return $?
  fi

  if [ -z "${MOSEQ_PROJECTS_BASE-}" ]; then
    echo "run moseq: environment not set up -- have you sourced pipelines/moseq/common/env_setup.sh? (see cli/setup.sh)" >&2
    exit 1
  fi
  case "$stage" in
    init)
      local name="${1-}"; shift || true
      moseq_validate_name "$name"
      local source=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --source) source="$2"; shift 2 ;;
          *) echo "run moseq init: unrecognized argument '$1'" >&2; exit 1 ;;
        esac
      done

      local project_dir
      project_dir="$(moseq_project_dir "$name")"
      if [ -d "$project_dir" ]; then
        echo "run moseq init: $project_dir already exists -- project names must be unique." >&2
        exit 1
      fi

      mkdir -p "$project_dir"
      # --source here only RECORDS the path, it never pulls -- init always
      # creates an empty project shell, no exceptions. This just saves
      # having to retype --source on the first `run moseq pull` afterward.
      moseq_write_meta "$project_dir" "$name" "$source"
      echo "run moseq init: created $project_dir"
      if [ -n "$source" ]; then
        echo "run moseq init: recorded gdrive_source=$source (not pulled yet) -- next: run moseq pull $name"
      else
        echo "run moseq init: no data pulled yet -- next: run moseq pull $name --source <gdrive_path>"
      fi
      ;;
    pull)
      local name="${1-}"; shift || true
      moseq_validate_name "$name"
      local source=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --source) source="$2"; shift 2 ;;
          *) echo "run moseq pull: unrecognized argument '$1'" >&2; exit 1 ;;
        esac
      done

      local project_dir
      project_dir="$(moseq_project_dir "$name")"
      if [ ! -d "$project_dir" ]; then
        echo "run moseq pull: $project_dir doesn't exist yet -- did you mean 'run moseq init $name' first?" >&2
        exit 1
      fi
      local meta_file="$project_dir/project_meta.yaml"

      if [ -z "$source" ]; then
        # No --source given -- fall back to whatever was recorded on init
        # or a previous pull, so re-syncing later doesn't require retyping
        # the Drive path every time.
        if [ -f "$meta_file" ]; then
          source="$(moseq_read_meta_field "$meta_file" "gdrive_source")"
        fi
        if [ -z "$source" ]; then
          echo "run moseq pull: --source is required (no gdrive_source recorded yet for '$name')" >&2
          exit 1
        fi
      fi

      # Submitted as a job, not run inline: rclone transfers of real Moseq
      # session data can be large (many GB), and Sherlock login nodes are
      # shared/rate-limited -- sustained transfers there risk throttling.
      # pull.sbatch runs on Sherlock's shared `normal` partition (never
      # illorent -- a non-exclusive job sitting on illorent would block the
      # lab's --exclusive compute jobs from starting, since --exclusive
      # needs the whole node free). This makes `run moseq pull`
      # asynchronous: it returns immediately with a job ID instead of
      # blocking with live --progress output the way it used to. Watch
      # progress with `run moseq logs pull <name>`, or just let it run.
      local log_dir="$project_dir/slurm_logs"
      mkdir -p "$log_dir"
      local job_output
      job_output="$(sbatch \
        "--output=$log_dir/pull-%j.out" \
        "--error=$log_dir/pull-%j.err" \
        "$MOSEQ_ROOT_DIR/sync/pull.sbatch" "$source" "$project_dir")"
      echo "$job_output"
      moseq_write_meta "$project_dir" "$name" "$source"
      echo "run moseq pull: recorded gdrive_source=$source in project_meta.yaml"
      echo "run moseq pull: watch progress with 'run logs moseq pull $name'"
      ;;
    projects)
      local found=0
      local meta_file
      for meta_file in "$MOSEQ_PROJECTS_BASE"/*/project_meta.yaml; do
        [ -e "$meta_file" ] || continue
        found=1
        local p_name p_path p_source p_created
        p_name="$(moseq_read_meta_field "$meta_file" "name")"
        p_path="$(moseq_read_meta_field "$meta_file" "sherlock_path")"
        p_source="$(moseq_read_meta_field "$meta_file" "gdrive_source")"
        p_created="$(moseq_read_meta_field "$meta_file" "created")"
        echo "$p_name"
        echo "  path:    $p_path"
        echo "  source:  $p_source"
        echo "  created: $p_created"
      done
      if [ "$found" -eq 0 ]; then
        echo "no moseq projects found under $MOSEQ_PROJECTS_BASE yet -- try 'run moseq init <name>'"
      fi
      ;;
    extract)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      _moseq_parse_resource_flags "$@"
      if [ ${#MOSEQ_REMAINING_ARGS[@]} -gt 0 ]; then
        echo "run moseq extract: unrecognized argument '${MOSEQ_REMAINING_ARGS[0]}'" >&2
        exit 1
      fi
      if [ "$MOSEQ_EXCLUSIVE" = "True" ]; then
        echo "run moseq extract: note -- --exclusive has no effect here, extraction always runs" >&2
        echo "  as a job array on Sherlock's shared 'normal' partition, not illorent (see" >&2
        echo "  extract_array.sbatch); 'run moseq master --exclusive' reserves illorent for" >&2
        echo "  the other stages in the chain instead." >&2
      fi
      moseq_python -c "
import submit_moseq
job_ids = submit_moseq.submit_extraction('$project_dir', exclusive=$MOSEQ_EXCLUSIVE, cores=$MOSEQ_CORES_PY, mem_gb=$MOSEQ_MEM_PY, time=$MOSEQ_TIME_PY)
if job_ids:
    print('submitted extraction jobs:', ', '.join(job_ids))
else:
    print('nothing to extract -- every session is already extracted (see run moseq check-progress $name)')
"
      ;;
    aggregate)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      _moseq_parse_resource_flags "$@"
      if [ ${#MOSEQ_REMAINING_ARGS[@]} -gt 0 ]; then
        echo "run moseq aggregate: unrecognized argument '${MOSEQ_REMAINING_ARGS[0]}'" >&2
        exit 1
      fi
      moseq_python -c "
import submit_moseq
print('submitted aggregate job:', submit_moseq.submit_aggregate('$project_dir', exclusive=$MOSEQ_EXCLUSIVE, cores=$MOSEQ_CORES_PY, mem_gb=$MOSEQ_MEM_PY, time=$MOSEQ_TIME_PY))
"
      ;;
    pca-fit)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      _moseq_parse_resource_flags "$@"
      if [ ${#MOSEQ_REMAINING_ARGS[@]} -gt 0 ]; then
        echo "run moseq pca-fit: unrecognized argument '${MOSEQ_REMAINING_ARGS[0]}'" >&2
        exit 1
      fi
      moseq_python -c "
import submit_moseq
print('submitted pca-fit job:', submit_moseq.submit_pca_fit('$project_dir', exclusive=$MOSEQ_EXCLUSIVE, cores=$MOSEQ_CORES_PY, mem_gb=$MOSEQ_MEM_PY, time=$MOSEQ_TIME_PY))
"
      ;;
    pca-apply)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      _moseq_parse_resource_flags "$@"
      if [ ${#MOSEQ_REMAINING_ARGS[@]} -gt 0 ]; then
        echo "run moseq pca-apply: unrecognized argument '${MOSEQ_REMAINING_ARGS[0]}'" >&2
        exit 1
      fi
      moseq_python -c "
import submit_moseq
print('submitted pca-apply job:', submit_moseq.submit_pca_apply('$project_dir', exclusive=$MOSEQ_EXCLUSIVE, cores=$MOSEQ_CORES_PY, mem_gb=$MOSEQ_MEM_PY, time=$MOSEQ_TIME_PY))
"
      ;;
    changepoints)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      _moseq_parse_resource_flags "$@"
      if [ ${#MOSEQ_REMAINING_ARGS[@]} -gt 0 ]; then
        echo "run moseq changepoints: unrecognized argument '${MOSEQ_REMAINING_ARGS[0]}'" >&2
        exit 1
      fi
      moseq_python -c "
import submit_moseq
print('submitted changepoints job:', submit_moseq.submit_compute_changepoints('$project_dir', exclusive=$MOSEQ_EXCLUSIVE, cores=$MOSEQ_CORES_PY, mem_gb=$MOSEQ_MEM_PY, time=$MOSEQ_TIME_PY))
"
      ;;
    kappa-scan)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      local n_models="10" scan_scale="log" min_kappa="" max_kappa="" num_iter="100"
      _moseq_parse_resource_flags "$@"
      set -- ${MOSEQ_REMAINING_ARGS[@]+"${MOSEQ_REMAINING_ARGS[@]}"}
      while [ $# -gt 0 ]; do
        case "$1" in
          --n-models)   n_models="$2"; shift 2 ;;
          --scan-scale) scan_scale="$2"; shift 2 ;;
          --min-kappa)  min_kappa="$2"; shift 2 ;;
          --max-kappa)  max_kappa="$2"; shift 2 ;;
          --num-iter)   num_iter="$2"; shift 2 ;;
          *) echo "run moseq kappa-scan: unrecognized argument '$1'" >&2; exit 1 ;;
        esac
      done
      moseq_python -c "
import submit_moseq
job_id = submit_moseq.submit_kappa_scan(
    '$project_dir',
    n_models=$n_models,
    scan_scale='$scan_scale',
    min_kappa=${min_kappa:-None},
    max_kappa=${max_kappa:-None},
    num_iter=$num_iter,
    exclusive=$MOSEQ_EXCLUSIVE,
    cores=$MOSEQ_CORES_PY,
    mem_gb=$MOSEQ_MEM_PY,
    time=$MOSEQ_TIME_PY,
)
print('submitted kappa-scan job:', job_id)
print('note: this also runs select_best_kappa.py automatically at the end -- check', '$project_dir/models/best_kappa_selection.json', 'once it finishes')
"
      ;;
    learn-model)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      local kappa="" num_iter="1000" dest_name="model.p"
      _moseq_parse_resource_flags "$@"
      set -- ${MOSEQ_REMAINING_ARGS[@]+"${MOSEQ_REMAINING_ARGS[@]}"}
      while [ $# -gt 0 ]; do
        case "$1" in
          --kappa)     kappa="$2"; shift 2 ;;
          --num-iter)  num_iter="$2"; shift 2 ;;
          --dest-name) dest_name="$2"; shift 2 ;;
          *) echo "run moseq learn-model: unrecognized argument '$1'" >&2; exit 1 ;;
        esac
      done
      if [ -z "$kappa" ]; then
        echo "run moseq learn-model: --kappa is required (see $project_dir/models/best_kappa_selection.json if you ran kappa-scan first)" >&2
        exit 1
      fi
      moseq_python -c "
import submit_moseq
job_id = submit_moseq.submit_learn_model('$project_dir', kappa=$kappa, num_iter=$num_iter, dest_name='$dest_name', exclusive=$MOSEQ_EXCLUSIVE, cores=$MOSEQ_CORES_PY, mem_gb=$MOSEQ_MEM_PY, time=$MOSEQ_TIME_PY)
print('submitted learn-model job:', job_id)
"
      ;;
    master)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      _moseq_parse_resource_flags "$@"
      if [ ${#MOSEQ_REMAINING_ARGS[@]} -gt 0 ] || [ "$MOSEQ_CORES_PY" != "None" ] || [ "$MOSEQ_MEM_PY" != "None" ] || [ "$MOSEQ_TIME_PY" != "None" ]; then
        echo "run moseq master: only --exclusive is supported here, not --cores/--mem/--time" >&2
        echo "  (5 very differently-sized stages are chained, a single cores/mem override" >&2
        echo "  wouldn't make sense across all of them) -- run each stage individually if" >&2
        echo "  you need to override one stage's cores/mem specifically." >&2
        exit 1
      fi
      moseq_python -c "
import json
import submit_moseq
jobs = submit_moseq.submit_master('$project_dir', exclusive=$MOSEQ_EXCLUSIVE)
print('submitted master chain (extract -> aggregate -> pca-fit -> pca-apply -> changepoints):')
print(json.dumps(jobs, indent=2))
print()
print('note: modeling (kappa-scan / learn-model) is NOT chained -- run those separately once changepoints finishes.')
if $MOSEQ_EXCLUSIVE:
    print('note: --exclusive applies to every stage above EXCEPT extraction, which always targets')
    print('      the shared normal partition (a job array), not illorent -- see submit_master()\'s docstring.')
"
      ;;
    check-progress)
      local name="${1-}"; shift || true
      local project_dir; project_dir="$(moseq_require_project "$name")"
      echo "sessions needing extraction:"
      moseq_python -c "
from reconcile_moseq_extraction import sessions_needing_extraction
needed = sessions_needing_extraction('$project_dir')
print('  ' + ', '.join(needed) if needed else '  (none -- every session extracted)')
"
      echo ""
      echo "pipeline progress (requires the container, may take a moment):"
      apptainer_python -c "
import sys
sys.path.insert(0, '$MOSEQ_COMMON_DIR')
from reconcile_moseq_progress import get_progress, pca_is_done, modeling_is_done, best_model_is_selected
progress = get_progress('$project_dir')
print('  pca done:            ', pca_is_done('$project_dir', progress))
print('  modeling done:       ', modeling_is_done('$project_dir', progress))
print('  best model selected: ', best_model_is_selected('$project_dir', progress))
"
      ;;
    "")
      echo "run: missing moseq stage -- try 'init', 'pull', 'projects', 'extract', 'aggregate', 'pca-fit', 'pca-apply', 'changepoints', 'kappa-scan', 'learn-model', 'master', or 'check-progress'" >&2
      exit 1
      ;;
    *)
      echo "run: unknown moseq stage '$stage'" >&2
      exit 1
      ;;
  esac
}

# Moseq logs live inside the project itself (<project>/slurm_logs/), one
# <stage>-<jobid>.out/.err pair per submission -- see submit_moseq.py's
# _log_flags() and pull's own explicit --output/--error flags above. Stage
# names here must match the exact strings used as the log-file prefix
# (underscores, not hyphens, e.g. "pca_fit" not "pca-fit"), even though the
# CLI subcommands themselves use hyphens (`run moseq pca-fit`) for
# readability -- this mapping bridges the two.
cmd_logs_moseq() {
  local stage="${1-}"; shift || true
  local name="${1-}"; shift || true
  if [ -z "$stage" ] || [ -z "$name" ]; then
    echo "run logs moseq: usage: run logs moseq <stage> <project_name>" >&2
    echo "  stages: pull, extract, aggregate, pca-fit, pca-apply, changepoints, kappa-scan, learn-model" >&2
    exit 1
  fi
  local file_prefix
  case "$stage" in
    pull)          file_prefix="pull" ;;
    extract)       file_prefix="extract" ;;
    aggregate)     file_prefix="aggregate" ;;
    pca-fit)       file_prefix="pca_fit" ;;
    pca-apply)     file_prefix="pca_apply" ;;
    changepoints)  file_prefix="changepoints" ;;
    kappa-scan)    file_prefix="kappa_scan" ;;
    learn-model)   file_prefix="learn_model" ;;
    *)
      echo "run logs moseq: unknown stage '$stage'" >&2
      exit 1
      ;;
  esac

  local project_dir; project_dir="$(moseq_require_project "$name")"
  local log_dir="$project_dir/slurm_logs"
  local latest
  latest="$(ls -t "$log_dir"/${file_prefix}-*.out 2>/dev/null | head -n1 || true)"
  if [ -z "$latest" ]; then
    echo "run logs moseq: no ${file_prefix} log found under $log_dir yet -- has 'run moseq $stage $name' been submitted? You may also try checking 'squeue -u $USER' to see if your job has been submitted or is in pending state." >&2
    exit 1
  fi
  echo "run logs: tailing $latest (Ctrl-C to stop)"
  tail -F "$latest"
}

moseq_job_names() {
  echo "moseq-pull,moseq-extract,moseq-aggregate,moseq-pca-fit,moseq-pca-apply,moseq-changepoints,moseq-kappa-scan,moseq-learn-model"
}

moseq_list_entry() {
  cat <<'EOF'
moseq
  init <name>         run moseq init <name> [--source <gdrive_path>]  (record-only)
  pull <name>         run moseq pull <name> [--source <gdrive_path>]  (async job, normal partition)
  projects            run moseq projects
  extract <name>      one job per session still needing extraction  [--exclusive|--cores N|--mem MEM|--time T]
  aggregate <name>    consolidate proc/ output, regenerate moseq2-index.yaml  [--exclusive|--cores N|--mem MEM|--time T]
  pca-fit <name>      fit PCA (also auto-selects npcs for 90% variance)  [--exclusive|--cores N|--mem MEM|--time T]
  pca-apply <name>    project sessions onto the fit PCA basis  [--exclusive|--cores N|--mem MEM|--time T]
  changepoints <name> model-free syllable changepoints from PCA scores  [--exclusive|--cores N|--mem MEM|--time T]
  kappa-scan <name>   [--n-models N --scan-scale log|linear --min-kappa --max-kappa --num-iter] [--exclusive|--cores N|--mem MEM|--time T]
  learn-model <name>  --kappa K [--num-iter --dest-name]  (final model fit) [--exclusive|--cores N|--mem MEM|--time T]
  master <name>       chains extract -> aggregate -> pca-fit -> pca-apply -> changepoints [--exclusive only]
  check-progress <name>  dry run: what's left to do for this project
EOF
}

# One-line usage for a single stage, used by `run moseq <stage> --help`.
# Keep in sync with moseq_help()'s per-stage lines below -- there's no
# single source of truth between the two on purpose (moseq_help's lines
# read naturally as part of a paragraph; these need to stand alone), but
# they should never actually say different things.
moseq_stage_usage() {
  case "$1" in
    init)           echo "usage: run moseq init <project_name> [--source <gdrive_path>]" ;;
    pull)           echo "usage: run moseq pull <project_name> [--source <gdrive_path>]" ;;
    projects)       echo "usage: run moseq projects" ;;
    extract)        echo "usage: run moseq extract <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    aggregate)      echo "usage: run moseq aggregate <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    pca-fit)        echo "usage: run moseq pca-fit <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    pca-apply)      echo "usage: run moseq pca-apply <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    changepoints)   echo "usage: run moseq changepoints <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    # TODO (future, not urgent): kappa-scan/learn-model only expose a
    # curated subset of moseq2-model's real CLI flags (n-models,
    # scan-scale, min/max-kappa, num-iter, kappa, dest-name). Someday it'd
    # be nice to let a caller pass arbitrary extra moseq2-model flags
    # straight through (e.g. --robust, --separate-trans, --hold-out) for
    # non-default runs, instead of this file needing a new named flag
    # added by hand every time moseq2-model grows one worth using. Not
    # implementing now -- current curated set covers everything actually
    # used so far.
    kappa-scan)     echo "usage: run moseq kappa-scan <project_name> [--n-models N --scan-scale log|linear --min-kappa K --max-kappa K --num-iter N] [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    learn-model)    echo "usage: run moseq learn-model <project_name> --kappa K [--num-iter N --dest-name NAME] [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    master)         echo "usage: run moseq master <project_name> [--exclusive]  (chains extract -> aggregate -> pca-fit -> pca-apply -> changepoints; --cores/--mem/--time not supported here)" ;;
    check-progress) echo "usage: run moseq check-progress <project_name>" ;;
    "")
      echo "usage: run moseq <stage> --help -- but no stage was given. Try 'run moseq help' for the full list." >&2
      return 1
      ;;
    *)
      echo "run moseq: unknown stage '$1' -- run 'run moseq help' for the full list" >&2
      return 1
      ;;
  esac
}

moseq_help() {
  cat <<'EOF'
  run moseq init <project_name> [--source <gdrive_path>]
  run moseq pull <project_name> [--source <gdrive_path>]
  run moseq projects
  run moseq extract <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq aggregate <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq pca-fit <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq pca-apply <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq changepoints <project_name> [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq kappa-scan <project_name> [--n-models N --scan-scale S --min-kappa K --max-kappa K --num-iter N] [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq learn-model <project_name> --kappa K [--num-iter N --dest-name NAME] [--exclusive] [--cores N] [--mem MEM] [--time T]
  run moseq master <project_name> [--exclusive]
  run moseq check-progress <project_name>
  run logs moseq <stage> <project_name>

--exclusive reserves the whole illorent node (it's a single node) for that
one run instead of the cores/mem resources.yaml calibrated for a typical
run of that stage -- for a genuinely huge/expensive dataset where it's
worth having all of it, not something to reach for routinely. Extraction
is the one stage this doesn't apply to the way you'd expect: it always
targets Sherlock's shared `normal` partition as a job array (see
extract_array.sbatch), not illorent, so `run moseq extract --exclusive`
is accepted but ignored there -- `run moseq master --exclusive` applies
--exclusive to aggregate/pca-fit/pca-apply/changepoints only, extraction
in that chain is unaffected either way.

--cores N / --mem MEM (plain number of GB, e.g. --mem 200 -- no unit
suffix) / --time T (Slurm duration, e.g. 2-00:00:00) override
resources.yaml's computed cores/mem/wall-time for that one invocation
only. Combinable with --exclusive -- when given together, the explicit
--cores/--mem/--time always win. --time has no registry-computed
equivalent at all today; this is the only way to change a stage's wall
time short of editing its .sbatch file's #SBATCH --time directive by
hand. NOT available on `run moseq master`: it chains five differently-
sized stages, so a single cores/mem/time number wouldn't mean the same
thing applied to all of them -- run a stage individually if you need to
override its cores/mem/time specifically.

`run moseq init <name> [--source <gdrive_path>]` creates
$MOSEQ_PROJECTS_BASE/<name> (canonical home for every lab member's Moseq
projects, see pipelines/moseq/common/env_setup.sh) and records name/Sherlock path in
$MOSEQ_PROJECTS_BASE/<name>/project_meta.yaml. It does NOT pull anything
from Drive, even if --source is given -- init always only creates the
empty project shell. Passing --source here just RECORDS the Drive path for
later (saves retyping it on the first pull); omit it and record it on the
first `run moseq pull` instead if you prefer. Project names must be unique
(enforced by directory existence).

`run moseq pull <name> [--source <gdrive_path>]` does the actual sync.
Submitted as a Slurm job (pull.sbatch) on Sherlock's shared `normal`
partition, not run inline and never on illorent -- real Drive transfers
can be large, login nodes are shared/rate-limited, and a non-exclusive job
sitting on illorent would block the lab's --exclusive compute jobs from
starting. This makes `run moseq pull` asynchronous: it returns immediately
with a job ID rather than blocking with live progress output. Watch it
with `run logs moseq pull <name>`. --source is required the first time (or
if init already recorded one, it's optional); once recorded, later calls
can drop --source and it reuses gdrive_source from project_meta.yaml.
<gdrive_path> can be any rclone remote path, not just something under the
default gdrive:Moseq/<name> convention. Deliberately a fully separate,
manual step from init -- unlike Miniscope, syncing only happens when you
explicitly ask for it.

`run moseq projects` lists every known project (name, Sherlock path, Drive
source) by scanning $MOSEQ_PROJECTS_BASE/*/project_meta.yaml -- each
project is self-describing, there's no separate central registry file to
keep in sync or race against.

`run moseq extract/aggregate/pca-fit/pca-apply/changepoints/kappa-scan/
learn-model/master <name>` are thin wrappers around submit_moseq.py's
functions -- same submission logic the project notebook can call too, just
via the CLI instead. All jobs run on the lab's single --exclusive illorent
node, so these queue strictly sequentially regardless of stage (unlike
`pull`, which runs on the shared `normal` partition since it's I/O-bound,
not compute). `run moseq master <name>` chains extract -> aggregate ->
pca-fit -> pca-apply -> changepoints via --dependency=afterok; kappa-scan/
learn-model are deliberately NOT included in that chain (picking a kappa
needs a decision between the scan and the final fit) -- run those two
explicitly once changepoints finishes. `run moseq check-progress <name>`
is a dry run showing what's left to do for one project (extraction status is
instant/host-side; PCA/modeling status needs the container and may take a
moment). `run moseq logs <stage> <name>` (or `run logs moseq <stage>
<name>`) tails that stage's most recent log under <project>/slurm_logs/.
EOF
}
