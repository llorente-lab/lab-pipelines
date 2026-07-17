#!/bin/bash
# Miniscope/CaImAn pipeline wiring for `run` (see cli/run, cli/pipelines.conf).
# Sourced by cli/run, not executed directly -- defines cmd_miniscope,
# cmd_logs_miniscope, cmd_queue_miniscope, miniscope_job_names,
# miniscope_list_entry, miniscope_help. Naming convention only, no magic:
# cli/run looks these up by pipeline name from cli/pipelines.conf.

# --- flag parsing shared by motion-correction/cnmfe/logs --------------------

parse_session_flags() {
  MOUSE=""
  DATE=""
  TP=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mouse) MOUSE="$2"; shift 2 ;;
      --date)  DATE="$2"; shift 2 ;;
      --tp)    TP="$2"; shift 2 ;;
      *) echo "run: unrecognized argument '$1'" >&2; usage; exit 1 ;;
    esac
  done
}

# Resolve the analyzed-data base the same way every other script does
# (matches motion_correct.py/cnmfe_modeling.py/sync.sh's own fallback, so
# `run logs` finds the exact same directory those scripts actually wrote to)
analyzed_base() {
  echo "${MINISCOPE_ANALYZED_BASE:-$SCRATCH/Miniscope/AnalyzedData}"
}

cmd_miniscope() {
  local stage="${1-}"; shift || true
  case "$stage" in
    motion-correction)
      parse_session_flags "$@"
      if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
        sbatch "$CAIMAN_MC_DIR/motion_correction.sbatch" "$MOUSE" "$DATE" "$TP"
      elif [ -n "$MOUSE" ]; then
        sbatch "$CAIMAN_MC_DIR/motion_correction.sbatch" "$MOUSE"
      else
        sbatch "$CAIMAN_MC_DIR/motion_correction.sbatch"
      fi
      ;;
    cnmfe)
      parse_session_flags "$@"
      if [ -n "$MOUSE" ] && [ -n "$DATE" ] && [ -n "$TP" ]; then
        sbatch "$CAIMAN_CNMFE_DIR/cnmfe.sbatch" "$MOUSE" "$DATE" "$TP"
      elif [ -n "$MOUSE" ]; then
        sbatch "$CAIMAN_CNMFE_DIR/cnmfe.sbatch" "$MOUSE"
      else
        sbatch "$CAIMAN_CNMFE_DIR/cnmfe.sbatch"
      fi
      ;;
    master)
      sbatch "$CAIMAN_ROOT_DIR/master_pipeline.sbatch"
      ;;
    "")
      echo "run: missing stage -- try 'motion-correction', 'cnmfe', or 'master'" >&2
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
  if [ "$stage" != "motion-correction" ] && [ "$stage" != "cnmfe" ]; then
    echo "run logs miniscope: stage must be 'motion-correction' or 'cnmfe'" >&2
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

# `run queue miniscope [--mouse M]` -- dry run, shows exactly what
# reconciliation currently thinks needs doing, without submitting anything.
# Reuses the same mc_queue()/cnmfe_queue() functions master_pipeline.sbatch
# itself calls before actually running anything, so this is guaranteed to
# show the real queue, not a separate reimplementation that could drift.
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
  echo "motion_correction,cnmfe,caiman_master,caiman_pipeline_test"
}

miniscope_list_entry() {
  cat <<'EOF'
miniscope
  motion-correction   run miniscope motion-correction [--mouse M [--date D --tp T]]
  cnmfe               run miniscope cnmfe             [--mouse M [--date D --tp T]]
  master              run miniscope master   (full sweep, hard-gated MC -> CNMF-E)
EOF
}

miniscope_help() {
  cat <<'EOF'
  run miniscope motion-correction [--mouse M [--date D --tp T]]
  run miniscope cnmfe             [--mouse M [--date D --tp T]]
  run miniscope master
  run queue miniscope [--mouse M]
  run logs miniscope <stage> --mouse M --date D --tp T

Granularity for motion-correction/cnmfe (matches the underlying .sbatch):
  no flags               full sweep, reconciliation-driven
  --mouse M              everything reconciliation finds for that mouse
  --mouse M --date D --tp T   exactly one session, runs directly

`run queue miniscope` is a dry run -- shows exactly which sessions
reconciliation currently thinks need motion correction or are ready for
CNMF-E, without submitting anything. Same underlying check
master_pipeline.sbatch itself uses before it runs anything for real.

Examples:
  run miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1
  run miniscope motion-correction --mouse VK_20250101_a
  run miniscope motion-correction
  run logs miniscope motion-correction --mouse VK_20250101_a --date 2025-01-01 --tp tp1
EOF
}
