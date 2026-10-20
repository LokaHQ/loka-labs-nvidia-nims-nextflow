#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Run inside the patched image to check its actual CPU writer and response schema."""

import json
import sys
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest


@unittest.skipUnless(Path("/opt/nim/api/pae_export.py").is_file(), "requires patched OpenFold3 image")
class ImageTests(unittest.TestCase):
    def test_real_tensors_writer_and_response_schema(self):
        sys.path.insert(0, "/opt/nim")
        import numpy as np
        import torch
        from biotite.structure import AtomArray
        from openfold3.core.data.io.structure.cif import write_structure
        from api.pae_export import export_confidence
        from api.dto.structure_with_scores import StructureWithScores

        atoms = AtomArray(3)
        atoms.coord = np.zeros((3, 3), dtype=np.float32)
        atoms.chain_id = np.array(["B", "B", "A"])
        atoms.res_id = np.array([18, 18, 2])
        atoms.ins_code = np.array(["A", "A", ""])
        atoms.res_name = np.array(["ALA", "ALA", "GLY"])
        atoms.atom_name = np.array(["CA", "CB", "CA"])
        atoms.element = np.array(["C", "C", "C"])
        atoms.set_annotation("b_factor", np.array([90.12345, 30.98765, 100]))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.pdb"
            write_structure(atoms, path)
            pdb = path.read_text()

        result = SimpleNamespace(
            batch={
                "atom_array": [atoms],
                "atom_mask": torch.tensor([[1, 1, 1, 0]]),
                "token_mask": torch.tensor([[1, 1, 0]]),
                "atom_to_token_index": torch.tensor([[1, 1, 0, 0]]),
            },
            outputs={"confidence_scores": {
                "plddt": torch.tensor([[[90.12345, 30.98765, 100, 0]]]),
                "pae": torch.tensor([[[[0.25, 2.5, 31.75], [8.75, 0.75, 31.75], [31.75] * 3]]]),
            }},
        )
        fields = export_confidence(result, 0, 0, pdb, "pdb")
        entry = StructureWithScores(
            structure=pdb, format="pdb", confidence_score=0.75,
            complex_plddt_score=70, complex_pde_score=5, ptm_score=0.6,
            iptm_score=0.8, **fields,
        )
        response = json.loads(entry.model_dump_json())
        self.assertEqual(response["pae"], [[0.25, 2.5], [8.75, 0.75]])
        self.assertEqual(response["pae_chain_ids"], ["A", "B"])
        self.assertEqual(response["pae_residue_ids"], ["2", "18A"])
        self.assertAlmostEqual(response["atom_plddt"][0], 90.12345, places=4)
        self.assertEqual(response["structure"], pdb)
        self.assertEqual(response["confidence_score"], 0.75)


if __name__ == "__main__":
    unittest.main()
