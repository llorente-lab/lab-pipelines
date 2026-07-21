#!/bin/bash
# Lightweight per-job CPU/memory sampler.
#
# Usage (call once after the job's project_root / log dir is known):
#
#   start_resource_monitor <log_file> [interval_seconds]
#
# Starts a background loop that appends one TSV row per interval.
# The loop stops automatically when the parent job exits (it's a child
# of this shell, so SLURM's cleanup kills it when the job ends).
#
# Log format (TSV, one header row then data):
#   timestamp        ISO-8601 local time
#   elapsed_s        seconds since monitor started
#   rss_mb           current RSS across all job processes (cgroup or ps fallback)
#   rss_pct          rss_mb / SLURM allocated mem * 100  (empty if mem unknown)
#   cpu_pct          %CPU across all job processes (cgroup cpuacct delta or ps)
#   nproc            number of processes sampled (cgroup task count or ps count)
#
# Cgroup paths (cgroup v1 layout used by most Slurm clusters):
#   memory: /sys/fs/cgroup/memory/slurm/uid_<uid>/job_<jobid>/memory.usage_in_bytes
#   cpu:    /sys/fs/cgroup/cpuacct/slurm/uid_<uid>/job_<jobid>/cpuacct.usage (ns)
#   tasks:  /sys/fs/cgroup/memory/slurm/uid_<uid>/job_<jobid>/tasks
# Falls back to `ps` if cgroup paths are not readable.

start_resource_monitor() {
    local log_file="$1"
    local interval="${2:-30}"

    # Resolve allocated memory from SLURM env (MB → for % calculation).
    local alloc_mb="${SLURM_MEM_PER_NODE:-0}"

    # Cgroup paths (cgroup v1).
    local uid; uid="$(id -u)"
    local job_id="${SLURM_JOB_ID:-}"
    local cg_mem=""
    local cg_cpu=""
    local cg_tasks=""
    if [ -n "$job_id" ]; then
        local cg_base="/sys/fs/cgroup/memory/slurm/uid_${uid}/job_${job_id}"
        local cg_cpu_base="/sys/fs/cgroup/cpuacct/slurm/uid_${uid}/job_${job_id}"
        [ -r "${cg_base}/memory.usage_in_bytes" ] && cg_mem="${cg_base}/memory.usage_in_bytes"
        [ -r "${cg_cpu_base}/cpuacct.usage" ]     && cg_cpu="${cg_cpu_base}/cpuacct.usage"
        [ -r "${cg_base}/tasks" ]                  && cg_tasks="${cg_base}/tasks"
    fi

    {
        printf 'timestamp\telapsed_s\trss_mb\trss_pct\tcpu_pct\tnproc\n' > "$log_file"
        local t0; t0="$(date +%s)"
        local prev_cpu_ns=0 prev_ts="$t0"

        while true; do
            local now; now="$(date +%s)"
            local elapsed=$(( now - t0 ))
            local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"

            # --- memory ---
            local rss_mb="" rss_pct=""
            if [ -n "$cg_mem" ]; then
                local bytes; bytes="$(cat "$cg_mem" 2>/dev/null || echo 0)"
                rss_mb=$(( bytes / 1048576 ))
            else
                # ps fallback: sum RSS of all processes in this session
                rss_mb="$(ps -e -o rss= 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')"
            fi
            if [ -n "$rss_mb" ] && [ "${alloc_mb:-0}" -gt 0 ] 2>/dev/null; then
                rss_pct="$(awk -v r="$rss_mb" -v a="$alloc_mb" 'BEGIN{printf "%.1f", r/a*100}')"
            fi

            # --- cpu ---
            local cpu_pct=""
            if [ -n "$cg_cpu" ]; then
                local cur_cpu_ns; cur_cpu_ns="$(cat "$cg_cpu" 2>/dev/null || echo 0)"
                local dt=$(( now - prev_ts ))
                if [ "$dt" -gt 0 ] && [ "$prev_cpu_ns" -gt 0 ]; then
                    # cpuacct.usage is cumulative nanoseconds across all cores.
                    # Divide by (dt_ns * ncpus) to get fraction → percentage.
                    local ncpus="${SLURM_CPUS_PER_TASK:-1}"
                    cpu_pct="$(awk -v dn="$(( cur_cpu_ns - prev_cpu_ns ))" \
                                   -v dt_ns="$(( dt * 1000000000 ))" \
                                   -v nc="$ncpus" \
                                   'BEGIN{printf "%.1f", dn/dt_ns/nc*100}')"
                fi
                prev_cpu_ns="$cur_cpu_ns"
                prev_ts="$now"
            else
                # ps fallback: instantaneous %cpu sum
                cpu_pct="$(ps -e -o %cpu= 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s}')"
            fi

            # --- nproc ---
            local nproc=""
            if [ -n "$cg_tasks" ]; then
                nproc="$(wc -l < "$cg_tasks" 2>/dev/null || echo "")"
            else
                nproc="$(ps -e -o pid= 2>/dev/null | wc -l)"
            fi

            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$ts" "$elapsed" "${rss_mb:-}" "${rss_pct:-}" "${cpu_pct:-}" "${nproc:-}" \
                >> "$log_file"

            sleep "$interval"
        done
    } &
    # Disown so the monitor survives `wait` calls in the parent but still
    # dies when the SLURM job ends (kernel cleans up the whole cgroup).
    disown $!
}
