#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Tests for OpenFold3 per-chain MSA preparation."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "openfold3_msa.py"
SPEC = importlib.util.spec_from_file_location("openfold3_msa", SCRIPT)
MSA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MSA)


def atom(serial: int, name: str, residue: str, chain: str, number: int) -> str:
    return (
        f"ATOM  {serial:5d} {name:^4s} {residue:3s} {chain}{number:4d}    "
        f"{0.0:8.3f}{0.0:8.3f}{0.0:8.3f}{1.0:6.2f}{50.0:6.2f}          C  "
    )


def complex_pdb() -> str:
    return "\n".join([
        atom(1, "CA", "ALA", "A", 1),
        atom(2, "CA", "GLY", "A", 2),
        atom(3, "CA", "SER", "B", 1),
        atom(4, "CA", "TYR", "B", 2),
    ]) + "\nEND\n"


class OpenFold3MsaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="openfold3-msa-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.pdb = self.root / "design.pdb"
        self.pdb.write_text(complex_pdb())

    def test_prepare_writes_binder_then_target(self) -> None:
        output = self.root / "query.fasta"
        MSA.prepare(self.pdb, "design_0", output)
        self.assertEqual(
            output.read_text(),
            ">design_0.A binder\nAG\n>design_0.B target\nSY\n",
        )

    def test_finalise_preserves_complete_alignments(self) -> None:
        binder = self.root / "binder.a3m"
        target = self.root / "target.a3m"
        binder_text = ">101\nAG\n>hit one\nA-\n"
        target_text = ">102\nSY\n>hit two\nSxY\n"
        binder.write_text(binder_text)
        target.write_text(target_text)
        output = self.root / "msas"
        MSA.finalise(self.pdb, "design_0", binder, target, output)
        self.assertEqual((output / "design_0.A.a3m").read_text(), binder_text)
        self.assertEqual((output / "design_0.B.a3m").read_text(), target_text)

    def test_finalise_rejects_swapped_or_empty_alignment(self) -> None:
        binder = self.root / "binder.a3m"
        target = self.root / "target.a3m"
        output = self.root / "msas"
        for binder_text, target_text in ((">q\nSY\n", ">q\nAG\n"), ("", ">q\nSY\n")):
            binder.write_text(binder_text)
            target.write_text(target_text)
            with self.subTest(binder=binder_text), self.assertRaises(ValueError):
                MSA.finalise(self.pdb, "design_0", binder, target, output)

    def test_design_id_must_be_a_filename_stem(self) -> None:
        with self.assertRaises(ValueError):
            MSA.prepare(self.pdb, "../design", self.root / "query.fasta")


if __name__ == "__main__":
    unittest.main()
