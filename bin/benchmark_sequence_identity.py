#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Compare the sequences the two pipelines' ProteinMPNN produced, per design.

RFdiffusion now gives both pipelines an identical backbone at the same seed, so
if the designs differ downstream the divergence enters here or later. This
measures how much: percent identity over the binder chain for each matched
design.

Sequences are read from the threaded PDBs (chain A is the binder by
convention), which both pipelines publish, rather than from FASTA, because the
two write FASTA headers differently.

Usage:
    benchmark_sequence_identity.py --baseline <dir> --nim <dir> [-o out.tsv]
"""

import argparse
import csv
import logging
import re
import sys
from pathlib import Path
from typing import NamedTuple

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
log = logging.getLogger(__name__)

THREE_TO_ONE = {
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q",
    "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K",
    "MET": "M", "PHE": "F", "PRO": "P", "SER": "S", "THR": "T", "TRP": "W",
    "TYR": "Y", "VAL": "V",
}

BASELINE_ID = re.compile(r"_(?P<design>\d+)_dldesign_\d+_mpnn(?P<replicate>\d+)$")
NIM_ID = re.compile(r"_(?P<design>\d+)_(?P<replicate>\d+)$")


class DesignKey(NamedTuple):
    design: int
    replicate: int


def parse_design_key(stem: str) -> DesignKey | None:
    for pattern in (BASELINE_ID, NIM_ID):
        match = pattern.search(stem)
        if match:
            return DesignKey(int(match["design"]), int(match["replicate"]))
    return None


def chain_sequence(pdb_path: Path, chain_id: str = "A") -> str:
    sequence: list[str] = []
    seen: set[str] = set()
    for line in pdb_path.read_text().splitlines():
        if not line.startswith("ATOM") or line[21] != chain_id or line[13:15] != "CA":
            continue
        residue = line[22:27]
        if residue in seen:
            continue
        seen.add(residue)
        sequence.append(THREE_TO_ONE.get(line[17:20].strip(), "X"))
    return "".join(sequence)


def collect(root: Path, label: str) -> dict[DesignKey, tuple[Path, str]]:
    if not root.is_dir():
        raise SystemExit(f"{label}: not a directory: {root}")
    found: dict[DesignKey, tuple[Path, str]] = {}
    for path in sorted(root.rglob("*.pdb")):
        key = parse_design_key(path.stem)
        if key is None:
            continue
        sequence = chain_sequence(path)
        if not sequence:
            log.warning("%s: no chain A in %s", label, path.name)
            continue
        # Several stages publish a PDB per design; the longest binder chain is
        # the threaded one, and earlier stages agree with it or are shorter.
        if key not in found or len(sequence) > len(found[key][1]):
            found[key] = (path, sequence)
    log.info("%s: %d design(s)", label, len(found))
    return found


def identity(left: str, right: str) -> tuple[float, int, int]:
    """Percent identity over the aligned prefix, plus the two lengths.

    No alignment is attempted: ProteinMPNN redesigns a fixed backbone, so the
    binder length is set by the backbone and the two should already match. A
    length difference is itself worth seeing, so it is reported rather than
    papered over by aligning.
    """
    shared = min(len(left), len(right))
    if shared == 0:
        return 0.0, len(left), len(right)
    matches = sum(1 for a, b in zip(left[:shared], right[:shared]) if a == b)
    return 100.0 * matches / shared, len(left), len(right)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--nim", type=Path, required=True)
    parser.add_argument("-o", "--output", default="-")
    args = parser.parse_args()

    baseline = collect(args.baseline, "baseline")
    nim = collect(args.nim, "nim")
    shared = sorted(set(baseline) & set(nim))
    if not shared:
        raise SystemExit("no designs present in both pipelines")

    rows = []
    for key in shared:
        baseline_seq = baseline[key][1]
        nim_seq = nim[key][1]
        percent, baseline_len, nim_len = identity(baseline_seq, nim_seq)
        rows.append({
            "design": key.design,
            "replicate": key.replicate,
            "identity_percent": f"{percent:.1f}",
            "baseline_length": baseline_len,
            "nim_length": nim_len,
            "identical": "yes" if baseline_seq == nim_seq else "no",
            "baseline_sequence": baseline_seq,
            "nim_sequence": nim_seq,
        })

    handle = sys.stdout if args.output == "-" else open(args.output, "w", newline="")
    try:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    finally:
        if handle is not sys.stdout:
            handle.close()

    mean = sum(float(row["identity_percent"]) for row in rows) / len(rows)
    log.info("%d design(s) compared, mean identity %.1f%%", len(rows), mean)
    return 0


if __name__ == "__main__":
    sys.exit(main())
