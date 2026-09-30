#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Exercise strict OpenFold3 confidence filtering without external packages."""

import sys
import csv
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "filter_openfold3_scores.py"
SPEC = importlib.util.spec_from_file_location("filter_openfold3_scores", SCRIPT)
FILTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FILTER)


class FilterOpenFold3ScoresTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.pdb = self.directory / "design_0.pdb"
        self.pdb.write_text("MODEL        1\nENDMDL\nEND\n")
        self.scores = self.directory / "scores.tsv"
        self.output = self.directory / "filtered.tsv"
        self.collection = self.directory / "collection"
        self.write_scores()

    def write_scores(self, **overrides: str) -> None:
        row = {
            "description": "design_0",
            "plddt_binder": "85.5",
            "plddt_target": "90.0",
            "pae_interaction": "8.0",
            "iptm_score": "0.7",
        }
        row.update(overrides)
        with self.scores.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(row), delimiter="\t")
            writer.writeheader()
            writer.writerow(row)

    def run_filter(self, filters: str = "plddt_binder>=80;pae_interaction<=10") -> bool:
        return FILTER.filter_scores(
            self.scores, self.pdb, filters, str(self.output), self.collection,
        )

    def assert_no_outputs(self) -> None:
        self.assertFalse(self.collection.exists())
        self.assertFalse(self.output.exists())

    def test_accepts_only_when_both_filters_pass_and_retains_columns(self) -> None:
        self.assertTrue(self.run_filter())
        copied = self.collection / "accepted" / self.pdb.name
        self.assertEqual(copied.read_bytes(), self.pdb.read_bytes())
        with self.output.open() as handle:
            row = next(csv.DictReader(handle, delimiter="\t"))
        self.assertEqual(row["openfold3_pass_filter"], "True")
        self.assertEqual(row["iptm_score"], "0.7")
        self.assertEqual(row["plddt_binder"], "85.5")
        self.assertEqual(row["pae_interaction"], "8.0")

    def test_rejects_if_either_supplied_filter_fails(self) -> None:
        for plddt, pae in (("79", "8"), ("85", "11"), ("79", "11")):
            with self.subTest(plddt=plddt, pae=pae):
                self.write_scores(plddt_binder=plddt, pae_interaction=pae)
                self.assertFalse(self.run_filter())
                self.assertTrue((self.collection / "rejected" / self.pdb.name).is_file())
                self.assertIn("False", self.output.read_text())

    def test_missing_pae_errors_even_if_first_filter_fails(self) -> None:
        self.write_scores(plddt_binder="20", pae_interaction="")
        with self.assertRaisesRegex(ValueError, "does not expose genuine PAE") as raised:
            self.run_filter()
        self.assertIn("PDE/ipTM cannot substitute", str(raised.exception))
        self.assertIn("integration is incomplete", str(raised.exception))
        self.assert_no_outputs()

    def test_blank_pae_allowed_when_not_requested(self) -> None:
        self.write_scores(pae_interaction="")
        self.assertTrue(self.run_filter("plddt_binder>=80"))

    def test_comparisons_and_scientific_notation(self) -> None:
        row = {"metric": "2"}
        for expression in (
            "metric<=2", "metric>=2", "metric==2", "metric!=3", "metric>1",
            "metric<3", "metric=2", " metric >= +2e0 ",
        ):
            with self.subTest(expression=expression):
                self.assertTrue(
                    FILTER.evaluate_filters(row, FILTER.parse_filters(expression))
                )
        self.assertFalse(FILTER.evaluate_filters(row, FILTER.parse_filters("metric>2")))

    def test_malformed_filters_never_create_outputs(self) -> None:
        for filters in (
            "", ";", "plddt_binder>=80;", "plddt_binder=>80",
            "plddt_binder>=80 junk", "plddt_binder>=80 or True",
            "plddt_binder>=nan", "plddt_binder>=inf", "plddt_binder>=1e999",
            "plddt_binder>=__import__('os')",
        ):
            with self.subTest(filters=filters):
                with self.assertRaises(ValueError):
                    self.run_filter(filters)
                self.assert_no_outputs()

    def test_unknown_and_missing_metrics_never_create_outputs(self) -> None:
        self.write_scores(iptm_score="")
        for filters in (
            "plddt_binder>99;unknown<1", "plddt_binder>99;iptm_score>0.5"
        ):
            with self.subTest(filters=filters):
                with self.assertRaises(ValueError):
                    self.run_filter(filters)
                self.assert_no_outputs()

    def test_description_must_match_predicted_pdb_stem(self) -> None:
        for description in ("", "other_design", "design_0.pdb", "../design_0"):
            with self.subTest(description=description):
                self.write_scores(description=description)
                with self.assertRaisesRegex(ValueError, "predicted PDB stem"):
                    self.run_filter()
                self.assert_no_outputs()

    def test_invalid_scores_never_create_outputs(self) -> None:
        for metric, value in (
            ("plddt_binder", "nan"), ("plddt_binder", "inf"),
            ("plddt_binder", "101"), ("plddt_binder", "-1"),
            ("plddt_binder", ""), ("plddt_target", "101"),
            ("plddt_target", "-1"), ("plddt_target", "nan"),
            ("pae_interaction", "-0.1"),
            ("pae_interaction", "inf"), ("pae_interaction", "nan"),
            ("pae_interaction", "bad"), ("iptm_score", "-inf"),
        ):
            with self.subTest(metric=metric, value=value):
                self.write_scores(**{metric: value})
                with self.assertRaises(ValueError):
                    self.run_filter("plddt_binder>99;pae_interaction<=10;iptm_score>0")
                self.assert_no_outputs()

    def test_invalid_tables_never_create_outputs(self) -> None:
        for contents in (
            "",
            "description\tplddt_binder\tpae_interaction\n",
            "description\tplddt_binder\tpae_interaction\ndesign_0\t85\t8\ndesign_0\t85\t8\n",
            "description\tplddt_binder\tplddt_binder\tpae_interaction\ndesign_0\t85\t85\t8\n",
            "description\tplddt_binder\tpae_interaction\ndesign_0\t85\n",
            "description\tplddt_binder\tpae_interaction\ndesign_0\t85\t8\textra\n",
            "description\tplddt_binder\ndesign_0\t85\n",
        ):
            with self.subTest(contents=contents):
                self.scores.write_text(contents)
                with self.assertRaises(ValueError):
                    self.run_filter()
                self.assert_no_outputs()

    def test_cli_stdout_and_failure_exit_status(self) -> None:
        command = [
            sys.executable, str(SCRIPT), "--scores", str(self.scores),
            "--pdb", str(self.pdb), "--filters", "plddt_binder>=80;pae_interaction<=10",
            "--collect-in", str(self.collection),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("openfold3_pass_filter", result.stdout)
        self.assertIn("accepted", result.stderr)
        self.write_scores(pae_interaction="")
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("integration is incomplete", result.stderr)


if __name__ == "__main__":
    unittest.main()
