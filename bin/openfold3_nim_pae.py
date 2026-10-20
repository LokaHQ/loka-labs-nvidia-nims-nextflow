#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Export existing OpenFold3 confidence tensors with verified PDB atom identities."""

from typing import Any
import math


def _vector(value: Any) -> list:
    return value.detach().cpu().reshape(-1).tolist()


def export_confidence(
    result: Any, batch_index: int, sample_index: int, pdb: str, output_format: str
) -> dict:
    """Serialise confidence tensors without changing model execution or ranking."""
    if output_format != "pdb":
        return {}

    batch = result.batch
    atoms = batch["atom_array"][batch_index]
    chains = [str(value) for value in atoms.chain_id]
    residues = [
        f"{int(number)}{str(insertion).strip()}"
        for number, insertion in zip(atoms.res_id, atoms.ins_code, strict=True)
    ]
    names = [str(value).strip() for value in atoms.atom_name]
    atom_keys = list(zip(chains, residues, names, strict=True))
    pdb_keys = [
        (line[21].strip(), line[22:26].strip() + line[26].strip(), line[12:16].strip())
        for line in pdb.splitlines()
        if line.startswith(("ATOM  ", "HETATM"))
    ]
    if not atom_keys or atom_keys != pdb_keys or len(set(atom_keys)) != len(atom_keys):
        raise ValueError("OpenFold3 confidence export cannot verify PDB atom identities")

    atom_mask = _vector(batch["atom_mask"][batch_index])
    atom_indices = [index for index, present in enumerate(atom_mask) if present]
    if atom_indices != list(range(len(atom_keys))):
        raise ValueError("OpenFold3 confidence export requires unambiguous real atom order")

    confidence = result.outputs["confidence_scores"]
    fields = {}
    plddt = confidence.get("plddt")
    if plddt is not None:
        values = _vector(plddt[batch_index][sample_index])
        if len(values) != len(atom_mask):
            raise ValueError("OpenFold3 pLDDT and atom-mask dimensions differ")
        values = [float(values[index]) for index in atom_indices]
        if any(not math.isfinite(value) or not 0 <= value <= 100 for value in values):
            raise ValueError("OpenFold3 pLDDT must contain finite values on the 0–100 scale")
        fields.update(
            atom_plddt=values,
            atom_chain_ids=chains,
            atom_residue_ids=residues,
            atom_names=names,
        )

    pae = confidence.get("pae")
    if pae is None:
        return fields

    matrix = pae[batch_index][sample_index].detach().float().cpu().tolist()
    token_mask = _vector(batch["token_mask"][batch_index])
    if len(matrix) != len(token_mask) or any(len(row) != len(token_mask) for row in matrix):
        raise ValueError("OpenFold3 PAE and token-mask dimensions differ")
    token_indices = [index for index, present in enumerate(token_mask) if present]
    atom_to_token = _vector(batch["atom_to_token_index"][batch_index])
    if len(atom_to_token) != len(atom_mask):
        raise ValueError("OpenFold3 atom-to-token and atom-mask dimensions differ")

    token_residues = {}
    for atom_index, (chain, residue, _) in zip(atom_indices, atom_keys, strict=True):
        token = int(atom_to_token[atom_index])
        identity = (chain, residue)
        if token in token_residues and token_residues[token] != identity:
            raise ValueError("OpenFold3 token spans multiple PDB residues")
        token_residues[token] = identity
    if set(token_residues) != set(token_indices):
        raise ValueError("OpenFold3 PAE tokens cannot all be mapped to PDB residues")
    ordered_residues = [token_residues[index] for index in token_indices]
    if len(set(ordered_residues)) != len(ordered_residues):
        raise ValueError("OpenFold3 residue PAE export requires one token per residue")

    matrix = [[float(matrix[i][j]) for j in token_indices] for i in token_indices]
    if any(not math.isfinite(value) or value < 0 for row in matrix for value in row):
        raise ValueError("OpenFold3 PAE must contain finite non-negative values")
    fields.update(
        pae=matrix,
        pae_chain_ids=[chain for chain, _ in ordered_residues],
        pae_residue_ids=[residue for _, residue in ordered_residues],
    )
    return fields
