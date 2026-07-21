"""
CLI `--help` smoke tests.

Loads the top-level click group from each package and invokes `--help` using
click's in-process test runner (no subprocess, no PATH assumptions). Catches
the same class of decorator-time errors as the recent Click 8.2+
`multiple=True` default breakage.
"""

import importlib

import pytest
from click.testing import CliRunner

CLIS = [
    ("moseq2_extract.cli", "cli"),
    ("moseq2_pca.cli", "cli"),
    ("moseq2_viz.cli", "cli"),
    ("moseq2_model.cli", "cli"),
]


@pytest.mark.parametrize("modname,attr", CLIS, ids=[m for m, _ in CLIS])
def test_cli_help(modname, attr):
    mod = importlib.import_module(modname)
    group = getattr(mod, attr)
    result = CliRunner().invoke(group, ["--help"])
    assert result.exit_code == 0, (
        f"{modname}:{attr} --help exited {result.exit_code}\n"
        f"stdout:\n{result.output}\n"
        f"exception: {result.exception!r}"
    )
