#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Co-fold a designed complex with OpenFold3 and normalise its confidence scores."""

from typing import Any
import logging
import sys
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import mean
import urllib.error
import urllib.request

AA_3_1 = {
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C",
    "GLN": "Q", "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I",
    "LEU": "L", "LYS": "K", "MET": "M", "PHE": "F", "PRO": "P",
    "SER": "S", "THR": "T", "TRP": "W", "TYR": "Y", "VAL": "V",
}
NATIVE_SCORES = [
    "confidence_score", "complex_plddt_score", "complex_pde_score",
    "ptm_score", "iptm_score",
]


def read_residues(pdb_text: str) -> dict:
    """Retain chain/residue identity and the original heavy-atom B-factors."""
    if not isinstance(pdb_text, str):
        raise ValueError("OpenFold3 structure must be PDB text")
    residues: dict = {}
    model_count = 0
    for line in pdb_text.splitlines():
        if line.startswith("MODEL"):
            model_count += 1
            if model_count > 1:
                raise ValueError("Expected one model per PDB")
        if not line.startswith("ATOM  "):
            continue
        if line[16:17] not in (" ", "A"):
            continue
        chain, residue_id = line[21:22], line[22:27].strip()
        name, atom = line[17:20].strip(), line[12:16].strip()
        if chain not in ("A", "B") or name not in AA_3_1:
            raise ValueError(f"Expected standard protein residues in chains A/B, got {chain}:{name}")
        element = line[76:78].strip() or atom.lstrip("0123456789")[:1]
        if element.upper() in ("H", "D"):
            continue
        key = (chain, residue_id)
        residue = residues.setdefault(key, {"name": name, "atoms": {}})
        if residue["name"] != name or atom in residue["atoms"]:
            raise ValueError(f"Ambiguous residue or duplicate atom at {key}:{atom}")
        residue["atoms"][atom] = float(line[60:66])
    if {key[0] for key in residues} != {"A", "B"}:
        raise ValueError("Expected both chain A (binder) and chain B (cropped target)")
    return residues


def chain_sequences(residues: dict) -> dict[str, str]:
    return {
        chain: "".join(AA_3_1[r["name"]] for key, r in residues.items() if key[0] == chain)
        for chain in ("A", "B")
    }


def read_a3m(path: Path, expected_sequence: str) -> str:
    """Read an A3M and verify that its first record is the exact query."""
    alignment = path.read_text()
    records = []
    header = None
    sequence = []
    for line in alignment.splitlines():
        if line.startswith(">"):
            if header is not None:
                records.append((header, "".join(sequence)))
            header = line
            sequence = []
        elif line.strip():
            if header is None:
                raise ValueError(f"A3M sequence appears before its first header: {path}")
            sequence.append(line.strip())
    if header is not None:
        records.append((header, "".join(sequence)))
    if not records:
        raise ValueError(f"A3M contains no records: {path}")
    if records[0][1] != expected_sequence:
        raise ValueError(f"A3M query does not match the complex sequence: {path}")
    for header, sequence in records:
        aligned_length = sum(not character.islower() for character in sequence)
        if aligned_length != len(expected_sequence):
            raise ValueError(
                f"A3M record {header} does not align to the full query length: {path}"
            )
    return alignment if alignment.endswith("\n") else alignment + "\n"


def build_complex_query(
    sequences: dict[str, str], design_id: str, alignments: dict[str, str]
) -> dict:
    return {"inputs": [{
        "input_id": design_id,
        "molecules": [{
            "type": "protein", "id": chain, "sequence": sequences[chain],
            "msa": {"main": {"a3m": {
                "alignment": alignments[chain], "format": "a3m",
            }}},
        } for chain in ("A", "B")],
        "diffusion_samples": 1,
        "output_format": "pdb",
    }]}


def chain_plddt(residues: dict, selected_chain: str) -> float:
    residue_means = []
    for (chain, residue_id), residue in residues.items():
        values = list(residue["atoms"].values())
        if not values or any(not math.isfinite(x) or not 0 <= x <= 100 for x in values):
            raise ValueError(f"Invalid atom pLDDT at {chain}:{residue_id}")
        if chain == selected_chain:
            residue_means.append(mean(values))
    if not residue_means:
        raise ValueError(f"No residues found for chain {selected_chain}")
    return mean(residue_means)


def binder_plddt(residues: dict) -> float:
    return chain_plddt(residues, "A")


def original_atom_confidence(entry: dict, residues: dict) -> dict:
    """Use unrounded model confidence when the response extension supplies it."""
    if "atom_plddt" not in entry:
        return residues
    arrays = [entry.get(key) for key in
              ("atom_plddt", "atom_chain_ids", "atom_residue_ids", "atom_names")]
    if any(not isinstance(a, list) for a in arrays) or len({len(a) for a in arrays}) != 1:
        raise ValueError("Atom confidence requires equally sized value and identity arrays")
    expected = {(chain, res_id, atom) for (chain, res_id), r in residues.items() for atom in r["atoms"]}
    values = {}
    for value, chain, res_id, atom in zip(*arrays):
        if not isinstance(chain, str) or not isinstance(atom, str) or not atom:
            raise ValueError("Atom confidence identities must contain chain and atom names")
        if atom.lstrip("0123456789").startswith(("H", "D")):
            continue
        key = (chain, str(res_id), atom)
        if key not in expected or key in values:
            raise ValueError("Atom confidence mapping does not match returned PDB")
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or not 0 <= value <= 100:
            raise ValueError("Invalid atom pLDDT; expected finite values on the 0-100 scale")
        values[key] = value
    if set(values) != expected:
        raise ValueError("Atom confidence mapping is incomplete")
    return {key: {"name": r["name"], "atoms": {
        atom: values[(*key, atom)] for atom in r["atoms"]
    }} for key, r in residues.items()}


def interaction_pae(entry: dict, residues: dict) -> float | None:
    """Only accept genuine PAE with an explicit row/column residue mapping."""
    pae = entry.get("pae")
    if pae is None:
        return None
    chains = entry.get("pae_chain_ids")
    residue_ids = entry.get("pae_residue_ids")
    if not isinstance(chains, list) or not isinstance(residue_ids, list):
        raise ValueError("PAE needs pae_chain_ids and pae_residue_ids; cannot guess matrix ordering")
    keys = list(zip(chains, map(str, residue_ids)))
    n = len(residues)
    if len(chains) != n or len(residue_ids) != n or len(set(keys)) != n or set(keys) != set(residues):
        raise ValueError("PAE residue mapping does not match the returned complex")
    if not isinstance(pae, list) or len(pae) != n or any(not isinstance(row, list) or len(row) != n for row in pae):
        raise ValueError("PAE matrix dimensions do not match its residue mapping")
    if any(not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) or v < 0 for row in pae for v in row):
        raise ValueError("PAE matrix contains invalid values")
    binder = [i for i, chain in enumerate(chains) if chain == "A"]
    target = [i for i, chain in enumerate(chains) if chain == "B"]
    return (mean(pae[i][j] for i in binder for j in target)
            + mean(pae[j][i] for i in binder for j in target)) / 2


def save_prediction(result: dict, sequences: dict[str, str], design_id: str,
                    output_dir: Path) -> dict[str, Any]:
    if not isinstance(result, dict):
        raise ValueError("OpenFold3 response must be a JSON object")
    outputs = result.get("outputs", [])
    if not isinstance(outputs, list) or len(outputs) != 1 or not isinstance(outputs[0], dict):
        raise ValueError("Expected exactly one OpenFold3 output")
    output = outputs[0]
    if output.get("input_id") != design_id:
        raise ValueError("OpenFold3 response input_id does not match this design")
    structures = output.get("structures_with_scores", [])
    if not isinstance(structures, list) or len(structures) != 1 or not isinstance(structures[0], dict):
        raise ValueError("Expected one structure for diffusion_samples=1")
    entry = structures[0]
    structure = entry["structure"]
    residues = read_residues(structure)
    if chain_sequences(residues) != sequences:
        raise ValueError("Returned chain sequences do not match binder A and cropped target B")
    confidence = original_atom_confidence(entry, residues)
    binder_confidence = chain_plddt(confidence, "A")
    target_confidence = chain_plddt(confidence, "B")
    pae = interaction_pae(entry, residues)
    (output_dir / "pdbs").mkdir(parents=True, exist_ok=True)
    (output_dir / "scores").mkdir(parents=True, exist_ok=True)
    (output_dir / "pdbs" / f"{design_id}.pdb").write_text(structure)
    row = {"description": design_id, "plddt_binder": binder_confidence,
           "plddt_target": target_confidence,
           "pae_interaction": "" if pae is None else pae,
           "filename": f"{design_id}.pdb"}
    row.update({key: entry.get(key, "") for key in NATIVE_SCORES})
    with (output_dir / "scores" / f"{design_id}.of3_scores.tsv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(row), delimiter="\t")
        writer.writeheader()
        writer.writerow(row)
    if pae is None:
        logging.warning("Genuine PAE is unavailable; pae_interaction is blank.")
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-pdb", type=Path, required=True)
    parser.add_argument("--binder-msa", type=Path, required=True)
    parser.add_argument("--target-msa", type=Path, required=True)
    parser.add_argument("--design-id", required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("."))
    parser.add_argument("--endpoint", default="http://localhost:8000/biology/openfold/openfold3/predict")
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--response-json", type=Path, help="Reprocess a saved response without inference")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
    try:
        if not args.design_id or Path(args.design_id).name != args.design_id or args.design_id in (".", ".."):
            raise ValueError("design-id must be a non-empty filename stem")
        sequences = chain_sequences(read_residues(args.input_pdb.read_text()))
        alignments = {
            "A": read_a3m(args.binder_msa, sequences["A"]),
            "B": read_a3m(args.target_msa, sequences["B"]),
        }
        payload = build_complex_query(sequences, args.design_id, alignments)
        raw_dir = args.output_dir / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)
        (raw_dir / f"{args.design_id}.request.json").write_text(json.dumps(payload, indent=2) + "\n")
        if args.response_json:
            response = args.response_json.read_bytes()
        else:
            request = urllib.request.Request(args.endpoint, data=json.dumps(payload).encode(),
                                             headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(request, timeout=args.timeout) as handle:
                response = handle.read()
        (raw_dir / f"{args.design_id}.response.json").write_bytes(response)
        row = save_prediction(json.loads(response), sequences, args.design_id, args.output_dir)
        logging.info("Saved %s: binder pLDDT %.4f, target pLDDT %.4f, interaction PAE %s",
                     args.design_id, row["plddt_binder"], row["plddt_target"],
                     row["pae_interaction"] or "unavailable")
    except urllib.error.HTTPError as exc:
        body = exc.read()
        (raw_dir / f"{args.design_id}.response.json").write_bytes(body)
        logging.error("OpenFold3 HTTP %s: %s", exc.code, body.decode(errors="replace"))
        return 1
    except (ValueError, KeyError, TypeError, OSError) as exc:
        logging.error("OpenFold3: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
