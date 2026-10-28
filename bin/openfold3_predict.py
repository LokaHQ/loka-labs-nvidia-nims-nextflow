#!/usr/bin/env python3
"""Co-fold binder (chain A) + target (chain B) sequences from each input PDB
using OpenFold3, in place of AF2 initial-guess refinement of a known structure.

Usage: openfold3_predict.py <input_dir> <pdbs_out_dir> <scores_out_dir> <runner_yaml>
                            [msa_dir]

With msa_dir, each query takes its per-chain alignments from
<msa_dir>/<query_id>.A.a3m and .B.a3m and OpenFold3's own MSA server is
disabled, so the alignments are the ones supplied rather than ones it fetches.
"""
import glob
import json
import shutil
import subprocess
import sys
from pathlib import Path

INPUT_DIR, PDBS_OUT, SCORES_OUT, RUNNER_YAML = sys.argv[1:5]
MSA_DIR = sys.argv[5] if len(sys.argv) > 5 else None

three_to_one = {
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q",
    "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K",
    "MET": "M", "PHE": "F", "PRO": "P", "SER": "S", "THR": "T", "TRP": "W",
    "TYR": "Y", "VAL": "V",
}


def chain_sequence(pdb_path, chain_id):
    seq = []
    seen = set()
    with open(pdb_path) as f:
        for line in f:
            if line.startswith("ATOM") and line[21] == chain_id and line[13:15] == "CA":
                resi = line[22:26]
                if resi in seen:
                    continue
                seen.add(resi)
                seq.append(three_to_one.get(line[17:20].strip(), "X"))
    return "".join(seq)


Path(PDBS_OUT).mkdir(parents=True, exist_ok=True)
Path(SCORES_OUT).mkdir(parents=True, exist_ok=True)

def msa_path(query_id, chain_id):
    """Path to a supplied per-chain alignment, named as openfold3_msa.py writes it."""
    path = Path(MSA_DIR) / f"{query_id}.{chain_id}.a3m"
    if not path.is_file():
        sys.exit(f"Missing alignment for {query_id} chain {chain_id}: {path}")
    return str(path)


queries = {}
for pdb_path in sorted(glob.glob(f"{INPUT_DIR}/*.pdb")):
    query_id = Path(pdb_path).stem
    chains = [
        {"molecule_type": "protein", "chain_ids": ["A"], "sequence": chain_sequence(pdb_path, "A")},
        {"molecule_type": "protein", "chain_ids": ["B"], "sequence": chain_sequence(pdb_path, "B")},
    ]
    if MSA_DIR:
        for chain in chains:
            chain["main_msa_file_paths"] = [msa_path(query_id, chain["chain_ids"][0])]
    queries[query_id] = {
        "chains": chains,
        # Paired-MSA queries hung indefinitely against the ColabFold server in
        # testing (single-chain MSAs completed in under a minute each). Pairing
        # isn't meaningful here anyway - the two chains aren't evolutionarily
        # related (one is a de novo binder). Per-chain MSAs still run.
        "use_paired_msas": False,
    }

query_json_path = Path("query.json")
query_json_path.write_text(json.dumps({"queries": queries}))

raw_out = Path("of3_raw_out")
command = [
    "run_openfold", "predict",
    f"--query_json={query_json_path}",
    f"--output_dir={raw_out}",
    f"--runner_yaml={RUNNER_YAML}",
]
if MSA_DIR:
    command.append("--use_msa_server=False")
subprocess.run(command, check=True)

for query_id in queries:
    pdb_matches = sorted(glob.glob(f"{raw_out}/{query_id}/seed_*/{query_id}_seed_*_sample_*.pdb"))
    conf_matches = sorted(glob.glob(f"{raw_out}/{query_id}/seed_*/{query_id}_seed_*_confidences_aggregated.json"))

    shutil.copy(pdb_matches[0], f"{PDBS_OUT}/{query_id}.pdb")

    conf = json.loads(Path(conf_matches[0]).read_text())
    with open(f"{SCORES_OUT}/{query_id}.scores.tsv", "w") as f:
        f.write("description\tavg_plddt\tptm\tiptm\tgpde\n")
        f.write(f"{query_id}\t{conf['avg_plddt']}\t{conf['ptm']}\t{conf['iptm']}\t{conf['gpde']}\n")
