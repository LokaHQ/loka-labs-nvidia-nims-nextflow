#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Run the real Nextflow confidence-filter module on local CPU fixtures.

Set NEXTFLOW_TEST_CMD to a Nextflow launcher command to enable these tests.
The launcher inherits NXF_HOME, NXF_VER and other runtime settings.
"""

import sys
import os
import csv
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
MODULE = REPOSITORY / "modules/local/rfd/openfold3_score_filter"
NEXTFLOW_COMMAND = shlex.split(os.environ.get("NEXTFLOW_TEST_CMD", ""))


def groovy_string(value: object) -> str:
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


@unittest.skipUnless(NEXTFLOW_COMMAND, "Set NEXTFLOW_TEST_CMD for Nextflow integration tests")
class OpenFold3NextflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="openfold3-nextflow-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.outdir = self.directory / "results"
        self.published = self.outdir / "rfd/openfold3_nim/filtered"
        self.runtime_bin = self.directory / "runtime_bin"
        self.runtime_bin.mkdir()
        (self.runtime_bin / "python").symlink_to(sys.executable)
        self.config = self.directory / "nextflow.config"
        self.config.write_text(
            "process.executor = 'local'\n"
            "process.maxForks = 2\n"
            "docker.enabled = false\n"
            "singularity.enabled = false\n"
            "apptainer.enabled = false\n"
            "conda.enabled = false\n"
            f"params.outdir = {groovy_string(self.outdir)}\n",
            encoding="utf-8",
        )

    def write_fixture(self, design_id: str, plddt: str, pae: str) -> tuple[str, Path, Path]:
        pdb = self.directory / f"{design_id}.pdb"
        pdb.write_text(f"REMARK fixture {design_id}\nEND\n", encoding="utf-8")
        scores = self.directory / f"{design_id}.of3_scores.tsv"
        with scores.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, delimiter="\t")
            writer.writerow(["description", "plddt_binder", "pae_interaction"])
            writer.writerow([design_id, plddt, pae])
        return design_id, pdb, scores

    def run_workflow(
        self,
        fixtures: list[tuple[str, Path, Path]],
        filters: str = "plddt_binder>=80;pae_interaction<=10",
    ) -> subprocess.CompletedProcess[str]:
        inputs = ",\n        ".join(
            f"tuple({groovy_string(design_id)}, file({groovy_string(pdb)}), "
            f"file({groovy_string(scores)}))"
            for design_id, pdb, scores in fixtures
        )
        workflow = self.directory / "main.nf"
        workflow.write_text(
            "nextflow.enable.dsl = 2\n"
            f"include {{ OPENFOLD3_SCORE_FILTER }} from {groovy_string(MODULE)}\n"
            "workflow {\n"
            f"    predictions = Channel.of(\n        {inputs}\n    )\n"
            f"    OPENFOLD3_SCORE_FILTER(predictions, {groovy_string(filters)})\n"
            '    OPENFOLD3_SCORE_FILTER.out.accepted.view { id, pdb -> "accepted|${id}|${pdb.name}" }\n'
            '    OPENFOLD3_SCORE_FILTER.out.rejected.view { id, pdb -> "rejected|${id}|${pdb.name}" }\n'
            '    OPENFOLD3_SCORE_FILTER.out.scores.view { id, scores -> "scores|${id}|${scores.name}" }\n'
            "}\n",
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["PATH"] = os.pathsep.join(
            [str(self.runtime_bin), str(REPOSITORY / "bin"), environment.get("PATH", "")]
        )
        return subprocess.run(
            [
                *NEXTFLOW_COMMAND, "-log", str(self.directory / "nextflow.log"),
                "run", str(workflow), "-c", str(self.config), "-ansi-log", "false",
                "-work-dir", str(self.directory / "work"),
            ],
            cwd=self.directory,
            env=environment,
            text=True,
            capture_output=True,
            timeout=180,
            check=False,
        )

    def test_prediction_tuples_keep_accepted_and_rejected_designs_paired(self) -> None:
        accepted = self.write_fixture("design_high", "90", "5")
        rejected = self.write_fixture("design_high_pae", "90", "15")
        result = self.run_workflow([rejected, accepted])
        diagnostic = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, diagnostic)
        for fixture, decision, passed in (
            (accepted, "accepted", "True"), (rejected, "rejected", "False")
        ):
            design_id, pdb, _ = fixture
            with self.subTest(design_id=design_id):
                self.assertIn(f"{decision}|{design_id}|{pdb.name}", diagnostic)
                self.assertIn(f"scores|{design_id}|{design_id}.filtered.tsv", diagnostic)
                self.assertEqual(
                    (self.published / decision / pdb.name).read_bytes(), pdb.read_bytes()
                )
                opposite = "rejected" if decision == "accepted" else "accepted"
                self.assertFalse((self.published / opposite / pdb.name).exists())
                with (self.published / f"{design_id}.filtered.tsv").open() as handle:
                    row = next(csv.DictReader(handle, delimiter="\t"))
                self.assertEqual(row["description"], design_id)
                self.assertEqual(row["openfold3_pass_filter"], passed)

    def test_missing_pae_fails_process_before_accepting_or_rejecting(self) -> None:
        missing = self.write_fixture("design_missing_pae", "20", "")
        result = self.run_workflow([missing])
        diagnostic = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, diagnostic)
        self.assertIn("does not expose genuine PAE", diagnostic)
        self.assertIn("PDE/ipTM cannot substitute", diagnostic)
        self.assertIn("integration is incomplete", diagnostic)
        self.assertNotIn("accepted|design_missing_pae", diagnostic)
        self.assertNotIn("rejected|design_missing_pae", diagnostic)
        self.assertFalse(list(self.published.rglob("*.pdb")))
        self.assertFalse(list(self.published.rglob("*.tsv")))


if __name__ == "__main__":
    unittest.main()
