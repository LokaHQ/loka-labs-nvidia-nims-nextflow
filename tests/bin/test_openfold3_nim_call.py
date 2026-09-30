#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Confidence and provenance checks for the OpenFold3 NIM client."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "openfold3_nim_call.py"
SPEC = importlib.util.spec_from_file_location("of3_client", SCRIPT)
CLIENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLIENT)


def atom(serial, name, residue, chain, number, score, element="C", insertion=" "):
    return (f"ATOM  {serial:5d} {name:^4s} {residue:3s} {chain}{number:4d}{insertion}   "
            f"{0.0:8.3f}{0.0:8.3f}{0.0:8.3f}{1.0:6.2f}{score:6.2f}          {element:>2s}  ")


def complex_pdb():
    return "\n".join([
        atom(1, "CA", "ALA", "A", 1, 90),
        atom(2, "CB", "ALA", "A", 1, 30),
        atom(3, "CA", "GLY", "A", 2, 100),
        atom(4, "H", "GLY", "A", 2, 0, "H"),
        atom(5, "CA", "SER", "B", 18, 50),
    ]) + "\nEND\n"


def response(pdb=None):
    return {"outputs": [{"input_id": "design_0", "structures_with_scores": [{
        "structure": pdb or complex_pdb(), "complex_plddt_score": 47.5,
        "complex_pde_score": 1.2, "iptm_score": 0.8,
    }]}]}


class ConfidenceTests(unittest.TestCase):
    def test_residue_balanced_heavy_atom_plddt(self):
        residues = CLIENT.read_residues(complex_pdb())
        self.assertEqual(CLIENT.binder_plddt(residues), 80)
        self.assertEqual(CLIENT.chain_plddt(residues, "B"), 50)
        self.assertNotEqual(CLIENT.binder_plddt(residues), (90 + 30 + 100) / 3)

    def test_sequence_and_crop_preserved(self):
        residues = CLIENT.read_residues(complex_pdb())
        alignments = {"A": ">binder\nAG\n>hit\nA-\n", "B": ">target\nS\n"}
        query = CLIENT.build_complex_query(
            CLIENT.chain_sequences(residues), "design_0", alignments
        )["inputs"][0]
        self.assertEqual(query["diffusion_samples"], 1)
        self.assertEqual(query["output_format"], "pdb")
        self.assertEqual([(m["id"], m["sequence"]) for m in query["molecules"]], [("A", "AG"), ("B", "S")])
        self.assertEqual(query["molecules"][0]["msa"]["main"]["a3m"]["alignment"], alignments["A"])
        self.assertEqual(query["molecules"][1]["msa"]["main"]["a3m"]["alignment"], alignments["B"])

    def test_a3m_query_must_match_exactly(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "query.a3m"
            path.write_text(">query\nAG\n>hit\nA-\n")
            self.assertEqual(CLIENT.read_a3m(path, "AG"), path.read_text())
            for content in ("", "AG\n", ">query\nA-G\n", ">query\nAg\n", ">query\nAG\n>hit\nA\n"):
                path.write_text(content)
                with self.subTest(content=content), self.assertRaises(ValueError):
                    CLIENT.read_a3m(path, "AG")

    def test_unrounded_model_confidence_by_atom_identity(self):
        residues = CLIENT.read_residues(complex_pdb())
        entry = {"atom_plddt": [50, 100, 30.123, 90.321],
                 "atom_chain_ids": ["B", "A", "A", "A"],
                 "atom_residue_ids": [18, 2, 1, 1],
                 "atom_names": ["CA", "CA", "CB", "CA"]}
        original = CLIENT.original_atom_confidence(entry, residues)
        self.assertAlmostEqual(CLIENT.binder_plddt(original), 80.111)
        self.assertEqual(CLIENT.binder_plddt(residues), 80)
        entry["atom_names"][3] = "CB"
        with self.assertRaisesRegex(ValueError, "mapping"):
            CLIENT.original_atom_confidence(entry, residues)

    def test_explicit_pae_mapping_and_both_directions(self):
        residues = CLIENT.read_residues(complex_pdb())
        entry = {"pae": [[0, 12, 8], [2, 0, 99], [6, 99, 0]],
                 "pae_chain_ids": ["B", "A", "A"], "pae_residue_ids": [18, 2, 1]}
        self.assertEqual(CLIENT.interaction_pae(entry, residues), 7)

    def test_missing_pae_is_not_pde_or_iptm(self):
        self.assertIsNone(CLIENT.interaction_pae({"complex_pde_score": 2, "iptm_score": 0.9}, CLIENT.read_residues(complex_pdb())))

    def test_pae_requires_verified_residue_mapping(self):
        residues = CLIENT.read_residues(complex_pdb())
        for entry in [
            {"pae": [[1]]},
            {"pae": [[1]], "pae_chain_ids": ["A"], "pae_residue_ids": [1]},
            {"pae": [[1]], "pae_chain_ids": ["A", "A", "B"], "pae_residue_ids": [1, 2, 18]},
        ]:
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                CLIENT.interaction_pae(entry, residues)

    def test_nan_pae_is_rejected(self):
        entry = {"pae": [[0, 1, float("nan")], [1, 0, 1], [1, 1, 0]],
                 "pae_chain_ids": ["A", "A", "B"], "pae_residue_ids": [1, 2, 18]}
        with self.assertRaisesRegex(ValueError, "invalid values"):
            CLIENT.interaction_pae(entry, CLIENT.read_residues(complex_pdb()))

    def test_insertion_codes_are_distinct(self):
        text = complex_pdb().replace("GLY A   2 ", "GLY A   1A")
        residues = CLIENT.read_residues(text)
        self.assertIn(("A", "1A"), residues)
        self.assertEqual(CLIENT.chain_sequences(residues)["A"], "AG")

    def test_chain_swaps_and_wrong_ids_fail(self):
        sequences = {"A": "AG", "B": "S"}
        with tempfile.TemporaryDirectory() as tmp:
            wrong_id = response()
            wrong_id["outputs"][0]["input_id"] = "another_design"
            with self.assertRaisesRegex(ValueError, "input_id"):
                CLIENT.save_prediction(wrong_id, sequences, "design_0", Path(tmp))
            swapped = complex_pdb().replace(" A ", " X ").replace(" B ", " A ").replace(" X ", " B ")
            with self.assertRaisesRegex(ValueError, "sequences"):
                CLIENT.save_prediction(response(swapped), sequences, "design_0", Path(tmp))
            with self.assertRaisesRegex(ValueError, "sequences"):
                CLIENT.save_prediction(response(), {"A": "AA", "B": "S"}, "design_0", Path(tmp))

    def test_replay_keeps_raw_json_and_missing_pae_blank(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "input.pdb").write_text(complex_pdb())
            (root / "binder.a3m").write_text(">query\nAG\n")
            (root / "target.a3m").write_text(">query\nS\n")
            original = json.dumps(response(), indent=3).encode()
            (root / "response.json").write_bytes(original)
            result = subprocess.run([sys.executable, str(SCRIPT), "--input-pdb", str(root / "input.pdb"),
                "--binder-msa", str(root / "binder.a3m"), "--target-msa", str(root / "target.a3m"),
                "--design-id", "design_0", "--response-json", str(root / "response.json"),
                "--output-dir", str(root / "output")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "output/raw/design_0.response.json").read_bytes(), original)
            self.assertEqual((root / "output/pdbs/design_0.pdb").read_text(), complex_pdb())
            self.assertIn("design_0\t80.0\t50.0\t\t", (root / "output/scores/design_0.of3_scores.tsv").read_text())

    def test_malformed_response_reports_validation_errors(self):
        cases = [None, [], {"outputs": None}, {"outputs": [None]},
                 {"outputs": [{"input_id": "design_0", "structures_with_scores": [None]}]}]
        invalid_structure = response()
        invalid_structure["outputs"][0]["structures_with_scores"][0]["structure"] = None
        cases.append(invalid_structure)
        with tempfile.TemporaryDirectory() as tmp:
            for result in cases:
                with self.subTest(result=result), self.assertRaises(ValueError):
                    CLIENT.save_prediction(result, {"A": "AG", "B": "S"}, "design_0", Path(tmp))


if __name__ == "__main__":
    unittest.main()
