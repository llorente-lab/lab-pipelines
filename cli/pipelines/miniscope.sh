#!/bin/bash

parse_session_flags() {
  MOUSE=""
  DATE=""
  TP=""
  EXCLUSIVE=""
  CORES=""
  MEM=""
  WALLTIME=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mouse)     MOUSE="$2"; shift 2 ;;
      --date)      DATE="$2"; shift 2 ;;
      --tp)        TP="$2"; shift 2 ;;
      --exclusive) EXCLUSIVE="1"; shift ;;
      --cores)     CORES="$2"; shift 2 ;;
      --mem)       MEM="$2"; shift 2 ;;
      --time)      WALLTIME="$2"; shift 2 ;;
      *) echo "run: unrecognized argument '$1'" >&2; usage; exit 1 ;;
    esac
  done
}

analyzed_base() {
  echo "${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"
}

cmd_miniscope() {
  local stage="${1-}"; shift || true

  if [ "$stage" = "help" ] || [ "$stage" = "--help" ] || [ "$stage" = "-h" ]; then
    miniscope_help
    return 0
  fi
  if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
    miniscope_stage_usage "$stage"
    return $?
  fi

  local _mail_flags=()
  if [ -n "${PIPELINE_NOTIFY_EMAIL:-}" ]; then
    _mail_flags=("--mail-type=FAIL" "--mail-user=${PIPELINE_NOTIFY_EMAIL}")
  fi

  case "$stage" in
    motion-correction)
      parse_session_flags "$@"
      if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
        _set_resource_flags miniscope motion-correction "n_sessions=1"
      elif [ -n "$MOUSE" ]; then
        _set_resource_flags miniscope motion-correction
      else
        _set_resource_flags miniscope motion-correction
      fi
      [ -n "$EXCLUSIVE" ] && _force_exclusive
      _apply_resource_overrides "$CORES" "$MEM" "$WALLTIME"
      if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
        _sbatch_submit "$(analyzed_base)/$MOUSE/$DATE/$TP/status" motion-correction \
          ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
          "$CAIMAN_MC_DIR/motion_correction.sbatch" "$MOUSE" "$DATE" "$TP"
      elif [ -n "$MOUSE" ]; then
        _sbatch_submit "$(analyzed_base)/$MOUSE/status" motion-correction \
          ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
          "$CAIMAN_MC_DIR/motion_correction.sbatch" "$MOUSE"
      else
        _sbatch_submit "$(analyzed_base)/status" motion-correction \
          ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
          "$CAIMAN_MC_DIR/motion_correction.sbatch"
      fi
      ;;
    cnmfe)
      parse_session_flags "$@"
      if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
        _set_resource_flags miniscope cnmfe "n_sessions=1"
      else
        _set_resource_flags miniscope cnmfe
      fi
      [ -n "$EXCLUSIVE" ] && _force_exclusive
      _apply_resource_overrides "$CORES" "$MEM" "$WALLTIME"
      if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
        _sbatch_submit "$(analyzed_base)/$MOUSE/$DATE/$TP/status" cnmfe \
          ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
          "$CAIMAN_CNMFE_DIR/cnmfe.sbatch" "$MOUSE" "$DATE" "$TP"
      elif [ -n "$MOUSE" ]; then
        _sbatch_submit "$(analyzed_base)/$MOUSE/status" cnmfe \
          ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
          "$CAIMAN_CNMFE_DIR/cnmfe.sbatch" "$MOUSE"
      else
        _sbatch_submit "$(analyzed_base)/status" cnmfe \
          ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
          "$CAIMAN_CNMFE_DIR/cnmfe.sbatch"
      fi
      ;;
    master)
      local exclusive="" cores="" mem="" walltime=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --exclusive) exclusive="1"; shift ;;
          --cores)     cores="$2"; shift 2 ;;
          --mem)       mem="$2"; shift 2 ;;
          --time)      walltime="$2"; shift 2 ;;
          *) echo "run miniscope master: unrecognized argument '$1'" >&2; exit 1 ;;
        esac
      done
      _set_resource_flags miniscope master
      [ -n "$exclusive" ] && _force_exclusive
      _apply_resource_overrides "$cores" "$mem" "$walltime"
      _sbatch_submit "$(analyzed_base)/status" master \
        ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
        "$CAIMAN_ROOT_DIR/master_pipeline.sbatch"
      ;;
    multisession)
      local mouse="" force_flag="" exclusive="" cores="" mem="" walltime=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --mouse)     mouse="$2"; shift 2 ;;
          --force)     force_flag="--force"; shift ;;
          --exclusive) exclusive="1"; shift ;;
          --cores)     cores="$2"; shift 2 ;;
          --mem)       mem="$2"; shift 2 ;;
          --time)      walltime="$2"; shift 2 ;;
          *) echo "run miniscope multisession: unrecognized argument '$1'" >&2; exit 1 ;;
        esac
      done
      _set_resource_flags miniscope multisession
      [ -n "$exclusive" ] && _force_exclusive
      _apply_resource_overrides "$cores" "$mem" "$walltime"
      # shellcheck disable=SC2086
      _sbatch_submit "$(analyzed_base)/status" multisession \
        ${RESOURCE_FLAGS[@]+"${RESOURCE_FLAGS[@]}"} ${_mail_flags[@]+"${_mail_flags[@]}"} \
        "$CAIMAN_ROOT_DIR/multisession/multisession_registration.sbatch" \
        ${mouse:+--mouse "$mouse"} $force_flag
      ;;
    dashboard)
      local mouse="${1-}"
      if [ -n "$mouse" ] && [ "$mouse" != "--mouse" ]; then
        echo "run miniscope dashboard: usage: run miniscope dashboard [--mouse M]" >&2
        exit 1
      fi
      [ "$mouse" = "--mouse" ] && mouse="${2-}"
      local search_dir
      search_dir="$(analyzed_base)"
      [ -n "$mouse" ] && search_dir="$search_dir/$mouse"
      if [ ! -d "$search_dir" ]; then
        echo "run miniscope dashboard: no data found under $search_dir" >&2
        exit 1
      fi
      python3 "$REPO_COMMON_DIR/dashboard.py" "$search_dir"
      ;;
    "")
      echo "run: missing stage -- try 'motion-correction', 'cnmfe', 'master', 'multisession', or 'dashboard'" >&2
      exit 1
      ;;
    *)
      echo "run: unknown miniscope stage '$stage'" >&2
      exit 1
      ;;
  esac
}

cmd_logs_miniscope() {
  local stage="${1-}"; shift || true

  if [ "$stage" = "multisession" ]; then
    local log_dir="$SCRATCH/logs/multisession_registration"
    local latest
    latest="$(ls -t "$log_dir"/*.out 2>/dev/null | head -n1 || true)"
    if [ -z "$latest" ]; then
      echo "run logs miniscope: no multisession log found under $log_dir yet -- has 'run miniscope multisession' been submitted?" >&2
      exit 1
    fi
    echo "run logs: tailing $latest (Ctrl-C to stop)"
    tail -F "$latest"
    return
  fi

  if [ "$stage" != "motion-correction" ] && [ "$stage" != "cnmfe" ]; then
    echo "run logs miniscope: stage must be 'motion-correction', 'cnmfe', or 'multisession'" >&2
    exit 1
  fi
  parse_session_flags "$@"
  if [ -z "$MOUSE" ] || [ -z "$DATE" ] || [ -z "$TP" ]; then
    echo "run logs miniscope: --mouse, --date, and --tp are all required" >&2
    exit 1
  fi

  local stage_tag="motion_correct"
  [ "$stage" = "cnmfe" ] && stage_tag="cnmfe"

  local log_dir
  log_dir="$(analyzed_base)/$MOUSE/$DATE/$TP/logs"
  local latest
  latest="$(ls -t "$log_dir"/${stage_tag}_*.log 2>/dev/null | head -n1 || true)"
  if [ -z "$latest" ]; then
    echo "run logs miniscope: no ${stage_tag} log found under $log_dir yet" >&2
    exit 1
  fi
  echo "run logs: tailing $latest (Ctrl-C to stop)"
  tail -F "$latest"
}

cmd_queue_miniscope() {
  parse_session_flags "$@"
  if [ -n "$DATE" ] || [ -n "$TP" ]; then
    echo "run queue: only --mouse is supported as a filter (not --date/--tp)" >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  source "$CAIMAN_COMMON_DIR/pipeline_common.sh"

  echo "sessions needing motion correction:"
  local mc_result
  mc_result="$(mc_queue "$MOUSE")"
  if [ -n "$mc_result" ]; then echo "$mc_result"; else echo "  (none)"; fi

  echo ""
  echo "sessions ready for CNMF-E:"
  local cnmfe_result
  cnmfe_result="$(cnmfe_queue "$MOUSE")"
  if [ -n "$cnmfe_result" ]; then echo "$cnmfe_result"; else echo "  (none)"; fi
}

miniscope_job_names() {
  echo "motion_correction,cnmfe,caiman_master,caiman_pipeline_test,multisession_registration"
}

miniscope_list_entry() {
  cat <<'EOF'
miniscope
  motion-correction   run miniscope motion-correction [--mouse M [--date D --tp T]] [--exclusive | --cores N --mem MEM --time T]
  cnmfe               run miniscope cnmfe             [--mouse M [--date D --tp T]] [--exclusive | --cores N --mem MEM --time T]
  master              run miniscope master   (full sweep, hard-gated MC -> CNMF-E) [--exclusive | --cores N --mem MEM --time T]
  multisession            run miniscope multisession [--mouse M] [--force] [--exclusive | --cores N --mem MEM --time T]
  dashboard                run miniscope dashboard [--mouse M]
EOF
}

miniscope_stage_usage() {
  case "$1" in
    motion-correction) echo "usage: run miniscope motion-correction [--mouse M [--date D --tp T]] [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    cnmfe)              echo "usage: run miniscope cnmfe [--mouse M [--date D --tp T]] [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    master)              echo "usage: run miniscope master  (full sweep, hard-gated MC -> CNMF-E) [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    multisession)         echo "usage: run miniscope multisession [--mouse M] [--force] [--exclusive] [--cores N] [--mem MEM] [--time T]" ;;
    dashboard)            echo "usage: run miniscope dashboard [--mouse M]" ;;
    "")
      echo "usage: run miniscope <stage> --help -- but no stage was given. Try 'run miniscope help' for the full list." >&2
      return 1
      ;;
    *)
      echo "run miniscope: unknown stage '$1' -- run 'run miniscope help' for the full list" >&2
      return 1
      ;;
  esac
}

miniscope_help() {
  cat <<'EOF'
  run miniscope motion-correction [--mouse M [--date D --tp T]] [--exclusive] [--cores N] [--mem MEM] [--time T]
  run miniscope cnmfe             [--mouse M [--date D --tp T]] [--exclusive] [--cores N] [--mem MEM] [--time T]
  run miniscope master                                          [--exclusive] [--cores N] [--mem MEM] [--time T]
  run miniscope multisession          [--mouse M] [--force]     [--exclusive] [--cores N] [--mem MEM] [--time T]
  run miniscope dashboard [--mouse M]
  run queue miniscope [--mouse M]
  run logs miniscope <stage> [--mouse M --date D --tp T]

Granularity for motion-correction/cnmfe (matches the underlying .sbatch):
  no flags               full sweep, reconciliation-driven
  --mouse M              everything reconciliation finds for that mouse
  --mouse M --date D --tp T   exactly one session, runs directly

--exclusive reserves the whole illorent node (it's a single node) for this
one run instead of the cores/mem numbers resources.yaml calibrated for a
typical run of that stage -- worth it for a genuinely huge/expensive
dataset, not something to reach for by default, since it competes for the
same shared node as everyone else's --exclusive jobs.

--cores N (integer) / --mem MEM (plain number of GB, e.g. --mem 200 -- the
G suffix is added for you, don't include it) / --time T (Slurm duration
format, e.g. 2-00:00:00) override resources.yaml's computed cores/mem/
wall-time for this one invocation only -- resources.yaml itself is
untouched. Combinable with --exclusive (an unusual but valid combination:
whole node reserved, but only part of it requested for this job) -- when
given together, the explicit --cores/--mem/--time always win. --time in
particular has no registry-computed equivalent at all right now; this is
the only way to change a stage's wall time short of editing its .sbatch
file directly.

`run miniscope multisession` runs CaImAn multisession registration across all
CNMF-E sessions for one or all mice. Finds model files from Drive, aligns
spatial footprints across sessions, and saves a single .joblib per mouse
back to gdrive:Miniscope/AnalyzedData/<mouse>/multisession_registration.joblib.
Skips mice that already have a result unless --force is given. Warns but
continues if not all sessions for a mouse have been modeled yet.

`run queue miniscope` is a dry run -- shows exactly which sessions
reconciliation currently thinks need motion correction or are ready for
CNMF-E, without submitting anything.

`run miniscope dashboard [--mouse M]` prints one row per job submitted
through this CLI (from status/jobs.jsonl next to each job's output, written
at submission time), with stage, submitted time, and current state -- live
state comes from `squeue -j`, otherwise from status/history.jsonl (written
by job_template.sh when a job finishes). Without --mouse, scans everything
under $MINISCOPE_ANALYZED_BASE; with --mouse, scans just that mouse's tree.

Examples:
  run miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1
  run miniscope motion-correction --mouse VK_20250101_a
  run miniscope motion-correction
  run miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1 --exclusive
  run miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1 --cores 200 --mem 1200 --time 2-00:00:00
  run miniscope multisession --mouse VK_20250101_a
  run miniscope multisession
  run miniscope multisession --force
  run logs miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1
  run logs miniscope multisession
EOF
}
