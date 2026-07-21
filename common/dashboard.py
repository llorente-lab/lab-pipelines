"""Shared job dashboard, used by both pipelines' `run <pipeline> dashboard` commands.

Reads status/jobs.jsonl (one line per submission: job_id/stage/submitted_at,
written at sbatch time) and status/history.jsonl (one line per finished run:
stage/status/start_time/end_time/exit_code/node/job_id, written by
job_template.sh's EXIT trap), cross-references live state via `squeue -j`,
and prints one table per directory given.

Usage: python3 dashboard.py <dir> [<dir> ...]
Each <dir> is searched recursively for jobs.jsonl/history.jsonl (moseq passes
one project dir; miniscope passes a mouse dir or the whole AnalyzedData root,
since it has no single project-root concept).
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def _read_jsonl(path: Path) -> list[dict]:
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def _live_states(job_ids: list[str]) -> dict[str, str]:
    """Best-effort `squeue -j` lookup; returns {} if squeue isn't available (e.g. local/test)."""
    if not job_ids:
        return {}
    try:
        out = subprocess.run(
            ["squeue", "-h", "-j", ",".join(job_ids), "-o", "%i|%T"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except Exception:
        return {}
    states = {}
    for line in out.strip().splitlines():
        if "|" not in line:
            continue
        jid, state = line.split("|", 1)
        states[jid] = state
    return states


def build_rows(search_dir: Path) -> list[dict]:
    jobs = []
    for f in search_dir.rglob("jobs.jsonl"):
        jobs.extend(_read_jsonl(f))

    history_by_job = {}
    for f in search_dir.rglob("history.jsonl"):
        for rec in _read_jsonl(f):
            jid = rec.get("job_id")
            if jid:
                history_by_job[jid] = rec

    live = _live_states([j["job_id"] for j in jobs if j.get("job_id")])

    rows = []
    for j in jobs:
        jid = j.get("job_id", "?")
        state = live.get(jid)
        if state is None:
            hist = history_by_job.get(jid)
            state = hist["status"] if hist else "unknown"
        rows.append({
            "job_id": jid,
            "stage": j.get("stage", "?"),
            "submitted_at": j.get("submitted_at", "?"),
            "state": state,
        })
    rows.sort(key=lambda r: r["submitted_at"])
    return rows


def print_dashboard(search_dir: Path) -> None:
    rows = build_rows(search_dir)
    if not rows:
        print(f"no job records found under {search_dir} yet")
        return
    print(f"{'JOB ID':<10} {'STAGE':<22} {'SUBMITTED':<20} {'STATE':<12}")
    print("-" * 66)
    for r in rows:
        print(f"{r['job_id']:<10} {r['stage']:<22} {r['submitted_at']:<20} {r['state']:<12}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: dashboard.py <dir> [<dir> ...]", file=sys.stderr)
        sys.exit(1)
    for i, d in enumerate(sys.argv[1:]):
        path = Path(d)
        if not path.is_dir():
            print(f"dashboard: {d}: no such directory", file=sys.stderr)
            continue
        if i > 0:
            print()
        print_dashboard(path)
