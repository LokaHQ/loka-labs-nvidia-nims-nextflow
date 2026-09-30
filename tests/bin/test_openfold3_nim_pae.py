#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Verify OpenFold3 confidence mapping without loading a GPU model."""

import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "bin" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EXPORTER = load_script("openfold3_nim_pae")
PATCHER = load_script("patch_openfold3_nim")


class Tensor:
    """Implement only the tensor operations used to serialise model results."""

    def __init__(self, data):
        self.data = data

    def __getitem__(self, index):
        return Tensor(self.data[index])

    def detach(self):
        return self

    def cpu(self):
        return self

    def float(self):
        return self

    def reshape(self, *shape):
        assert shape == (-1,)

        def flatten(value):
            if isinstance(value, list):
                return [item for group in value for item in flatten(group)]
            return [value]

        return Tensor(flatten(self.data))

    def tolist(self):
        return copy.deepcopy(self.data)


def atom(serial, name, chain, number, insertion=" "):
    return (
        f"ATOM  {serial:5d} {name:^4s} ALA {chain}{number:4d}{insertion}   "
        f"{0.0:8.3f}{0.0:8.3f}{0.0:8.3f}{1.0:6.2f}{50.0:6.2f}           C  "
    )


def fixture():
    atoms = SimpleNamespace(
        chain_id=["B", "B", "A"],
        res_id=[18, 18, 2],
        ins_code=["A", "A", ""],
        atom_name=["CA", "CB", "CA"],
    )
    result = SimpleNamespace(
        batch={
            "atom_array": [atoms],
            "atom_mask": Tensor([[1, 1, 1, 0]]),
            "token_mask": Tensor([[1, 1, 0]]),
            "atom_to_token_index": Tensor([[1, 1, 0, 0]]),
        },
        outputs={"confidence_scores": {
            "plddt": Tensor([[[90.12345, 30.98765, 100, 0]]]),
            "pae": Tensor([[[[0.25, 2.5, 31.75], [8.75, 0.75, 31.75], [31.75] * 3]]]),
            "pde": Tensor([[[[1, 1, 1]] * 3]]),
        }},
    )
    pdb = "\n".join([
        atom(1, "CA", "B", 18, "A"), atom(2, "CB", "B", 18, "A"),
        atom(3, "CA", "A", 2), "END",
    ]) + "\n"
    return result, pdb


class ExportTests(unittest.TestCase):
    def test_original_confidence_and_feature_mapping_are_preserved(self):
        result, pdb = fixture()
        before = copy.deepcopy(result.outputs["confidence_scores"]["pae"].data)
        fields = EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")
        self.assertEqual(fields["pae"], [[0.25, 2.5], [8.75, 0.75]])
        self.assertEqual(fields["pae_chain_ids"], ["A", "B"])
        self.assertEqual(fields["pae_residue_ids"], ["2", "18A"])
        self.assertEqual(fields["atom_plddt"], [90.12345, 30.98765, 100])
        self.assertEqual(fields["atom_chain_ids"], ["B", "B", "A"])
        self.assertEqual(fields["atom_residue_ids"], ["18A", "18A", "2"])
        self.assertEqual(fields["atom_names"], ["CA", "CB", "CA"])
        self.assertEqual(result.outputs["confidence_scores"]["pae"].data, before)

    def test_selects_matching_batch_and_sample(self):
        result, pdb = fixture()
        for name, value in result.batch.items():
            if isinstance(value, Tensor):
                value.data = [value.data[0], value.data[0]]
        result.batch["atom_array"] *= 2
        for value in result.outputs["confidence_scores"].values():
            sample = value.data[0][0]
            value.data = [[sample, sample], [sample, sample]]
        result.outputs["confidence_scores"]["pae"].data[1][1] = [[0.25, 9, 0], [3, 0.25, 0], [0, 0, 0]]
        fields = EXPORTER.export_confidence(result, 1, 1, pdb, "pdb")
        self.assertEqual(fields["pae"], [[0.25, 9], [3, 0.25]])

    def test_no_pae_is_not_replaced_by_pde(self):
        result, pdb = fixture()
        del result.outputs["confidence_scores"]["pae"]
        fields = EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")
        self.assertNotIn("pae", fields)
        self.assertIn("atom_plddt", fields)

    def test_cif_keeps_existing_response(self):
        self.assertEqual(EXPORTER.export_confidence(None, 0, 0, "", "cif"), {})

    def test_reordered_pdb_atoms_are_rejected(self):
        result, pdb = fixture()
        lines = pdb.splitlines()
        lines[0], lines[1] = lines[1], lines[0]
        with self.assertRaisesRegex(ValueError, "PDB atom identities"):
            EXPORTER.export_confidence(result, 0, 0, "\n".join(lines), "pdb")

    def test_interior_masking_is_rejected(self):
        result, pdb = fixture()
        result.batch["atom_mask"] = Tensor([[1, 0, 1, 1]])
        with self.assertRaisesRegex(ValueError, "real atom order"):
            EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")

    def test_token_spanning_two_residues_is_rejected(self):
        result, pdb = fixture()
        result.batch["atom_to_token_index"] = Tensor([[0, 0, 0, 0]])
        with self.assertRaisesRegex(ValueError, "spans multiple"):
            EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")

    def test_atomised_residue_is_rejected(self):
        result, pdb = fixture()
        result.batch["token_mask"] = Tensor([[1, 1, 1]])
        result.batch["atom_to_token_index"] = Tensor([[0, 1, 2, 0]])
        with self.assertRaisesRegex(ValueError, "one token per residue"):
            EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")

    def test_unmapped_pae_token_is_rejected(self):
        result, pdb = fixture()
        result.batch["token_mask"] = Tensor([[1, 1, 1]])
        with self.assertRaisesRegex(ValueError, "cannot all be mapped"):
            EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")

    def test_invalid_confidence_values_are_rejected(self):
        for score in [float("nan"), float("inf"), -1, 101]:
            with self.subTest(plddt=score):
                result, pdb = fixture()
                result.outputs["confidence_scores"]["plddt"].data[0][0][0] = score
                with self.assertRaisesRegex(ValueError, "pLDDT must"):
                    EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")
        for score in [float("nan"), float("inf"), -1]:
            with self.subTest(pae=score):
                result, pdb = fixture()
                result.outputs["confidence_scores"]["pae"].data[0][0][0][1] = score
                with self.assertRaisesRegex(ValueError, "PAE must"):
                    EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")

    def test_matrix_dimension_mismatch_is_rejected(self):
        result, pdb = fixture()
        result.outputs["confidence_scores"]["pae"].data[0][0].pop()
        with self.assertRaisesRegex(ValueError, "token-mask dimensions"):
            EXPORTER.export_confidence(result, 0, 0, pdb, "pdb")


class PatchTests(unittest.TestCase):
    def test_different_sources_are_rejected_before_any_patch(self):
        sources = {name: b"unknown upstream version" for name in PATCHER.EXPECTED_SHA256}
        with self.assertRaisesRegex(ValueError, "Unsupported OpenFold3 source"):
            PATCHER.patch_sources(sources)

    def test_missing_or_ambiguous_anchor_is_rejected(self):
        for source in ["", "anchor\nanchor"]:
            with self.subTest(source=source):
                with self.assertRaisesRegex(ValueError, "exactly one patch anchor"):
                    PATCHER.replace_once(source, "anchor", "replacement")


if __name__ == "__main__":
    unittest.main()
