# tests/

Test the pipeline's pieces individually without running a full real session.
Three tiers, fastest first.

## 1. Reconciliation logic (no Sherlock needed)

`test_reconcile_common.py` unit-tests `reconcile_common.py` directly, with
rclone calls mocked out. Pure stdlib, runs anywhere Python 3.9+ exists,
including your laptop:

    python tests/test_reconcile_common.py

Covers: `gdrive_path()` prefix handling, `discover_raw_sessions()` filtering
(the exact CaImAn/.git and tests/ pollution bug hit earlier), excluded-mice
merging, marker-dir matching at both tp-level and mouse/date-level, and
`find_local_mmap()`/`find_local_zip()` against a real temp directory.

## 2. CNMF-E path resolution (needs the container)

`test_path_resolution.py` unit-tests `resolve_analyzed_path()` from
`cnmfe_modeling.py`: tp-level vs mouse/date-level fallback, and the error
message when neither candidate is complete. Needs caiman importable, so run
it inside the container:

    apptainer_python tests/test_path_resolution.py

## 3. Full MC + sync smoke test (needs Sherlock, ~2 minutes)

`run_mc_sync_test.sbatch` generates a tiny synthetic session (90 frames,
100x100, via `generate_sample_data.py`), runs the real `motion_correct.py`
on it, then the real `sync.sh`, and checks the expected files landed both on
local scratch and on Drive.

    sbatch tests/run_mc_sync_test.sbatch

Job output lands at `$SCRATCH/logs/caiman_pipeline_test/<jobid>.out`
(the global, organized log location every stage now uses, set via
`SBATCH_OUTPUT`/`SBATCH_ERROR` in `env_setup.sh`).

Uses a dedicated identity, `pipeline_test_mouse/2020-01-01/test-session`,
which never starts with `VK_`, so real reconciliation can never pick it up.
Everything it touches lives under a `_pipeline_test` sandbox, both on
scratch (`$SCRATCH/Miniscope/_pipeline_test/`) and on Drive
(`gdrive:Miniscope/_pipeline_test/`), completely separate from real
`RawData`/`AnalyzedData`.

Run `cleanup_test_data.sh` afterward to remove everything it left behind:

    bash tests/cleanup_test_data.sh

## What's not covered here

CNMF-E's actual model fit isn't smoke-tested end to end -- synthesizing a
meaningful ROI `.zip` plus a correlation structure CNMF-E can seed against
is a lot of extra machinery for a test whose main value is speed. Test 2
above covers CNMF-E's path-resolution logic, which is the part most likely
to break (missing files, wrong depth). If you want a full CNMF-E run
tested, point `cnmfe_modeling.py` at a real session that already has an ROI
zip, using `cnmfe.sbatch <mouse> <date> <tp>` directly.
