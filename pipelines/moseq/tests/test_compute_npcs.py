#!/usr/bin/env python
"""
Unit tests for compute_npcs.py's npcs_for_variance() -- the actual
selection math (cumulative-variance threshold crossing), split out
specifically so it's testable with just numpy, no h5py/container needed.
compute_npcs()/update_config_npcs() (the h5py- and ruamel.yaml-dependent
parts) are NOT covered here, they need the container -- only syntax-checked
by deploy_check.sh.

Usage:
    python test_compute_npcs.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pca"))
from compute_npcs import npcs_for_variance


class TestNpcsForVariance(unittest.TestCase):

    def test_exact_threshold_crossing(self):
        # cumulative: 50, 80, 91, 95 -- crosses 90% at the 3rd PC
        evr = [0.50, 0.30, 0.11, 0.04]
        self.assertEqual(npcs_for_variance(evr, threshold=90.0), 3)

    def test_first_pc_alone_meets_threshold(self):
        evr = [0.95, 0.03, 0.02]
        self.assertEqual(npcs_for_variance(evr, threshold=90.0), 1)

    def test_needs_every_pc(self):
        evr = [0.20, 0.20, 0.20, 0.20, 0.19]  # cumulative maxes at 99%
        self.assertEqual(npcs_for_variance(evr, threshold=99.5), 5)

    def test_threshold_never_reached_falls_back_to_all_pcs(self):
        evr = [0.10, 0.10, 0.10]  # cumulative maxes at 30%
        self.assertEqual(npcs_for_variance(evr, threshold=90.0), 3)

    def test_exactly_at_threshold_counts_as_crossing(self):
        evr = [0.45, 0.45]  # cumulative: 45, 90 -- exactly 90 at PC 2
        self.assertEqual(npcs_for_variance(evr, threshold=90.0), 2)

    def test_different_threshold(self):
        evr = [0.50, 0.30, 0.11, 0.04]
        self.assertEqual(npcs_for_variance(evr, threshold=50.0), 1)
        self.assertEqual(npcs_for_variance(evr, threshold=80.0), 2)
        self.assertEqual(npcs_for_variance(evr, threshold=95.0), 4)

    def test_single_pc(self):
        self.assertEqual(npcs_for_variance([1.0], threshold=90.0), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
