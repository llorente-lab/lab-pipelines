#!/bin/bash
# DEPRECATED -- dead code, removed as part of a refactor collapsing this
# into extract.sbatch. submit_moseq.py's submit_extraction() only ever
# called extract.sbatch (which loops every unextracted session in one
# job); this per-session variant was never actually wired up to anything.
# Not read by any script anymore. Safe to delete -- kept only because this
# environment couldn't remove the file directly (filesystem permission
# issue on the mounted folder, same as cli/pipelines.conf's deprecation
# earlier) -- please `git rm moseq/extract/extract_session.sbatch`
# yourself.
