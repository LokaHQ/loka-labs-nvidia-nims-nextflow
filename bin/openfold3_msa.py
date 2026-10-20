#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Prepare and validate independent chain MSAs for OpenFold3 NIM."""

import argparse
import logging
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from openfold3_nim_call import chain_sequences, read_a3m, read_residues


def validate_design_id(design_id: str) -> None:
    if not design_id or Path(design_id).name != design_id or design_id in (".", ".."):
        raise ValueError("design-id must be a non-empty filename stem")


def sequences_from_pdb(path: Path) -> dict[str, str]:
    sequences = chain_sequences(read_residues(path.read_text()))
    if any(not sequence for sequence in sequences.values()):
        raise ValueError("Expected non-empty chain A and B sequences")
    return sequences


def prepare(input_pdb: Path, design_id: str, output: Path) -> None:
    validate_design_id(design_id)
    sequences = sequences_from_pdb(input_pdb)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        f">{design_id}.A binder\n{sequences['A']}\n"
        f">{design_id}.B target\n{sequences['B']}\n"
    )


def finalise(
    input_pdb: Path,
    design_id: str,
    binder_msa: Path,
    target_msa: Path,
    output_dir: Path,
) -> None:
    validate_design_id(design_id)
    sequences = sequences_from_pdb(input_pdb)
    sources = {"A": binder_msa, "B": target_msa}
    alignments = {
        chain: read_a3m(source, sequences[chain])
        for chain, source in sources.items()
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    for chain, alignment in alignments.items():
        destination = output_dir / f"{design_id}.{chain}.a3m"
        destination.write_text(alignment)
        record_count = sum(line.startswith(">") for line in alignment.splitlines())
        logging.info("Saved %s with %d sequence(s)", destination, record_count)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare", help="write a two-chain search FASTA")
    prepare_parser.add_argument("--input-pdb", type=Path, required=True)
    prepare_parser.add_argument("--design-id", required=True)
    prepare_parser.add_argument("--output", type=Path, required=True)

    finalise_parser = subparsers.add_parser("finalise", help="validate and name returned A3Ms")
    finalise_parser.add_argument("--input-pdb", type=Path, required=True)
    finalise_parser.add_argument("--design-id", required=True)
    finalise_parser.add_argument("--binder-msa", type=Path, required=True)
    finalise_parser.add_argument("--target-msa", type=Path, required=True)
    finalise_parser.add_argument("--output-dir", type=Path, required=True)

    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
    try:
        if args.command == "prepare":
            prepare(args.input_pdb, args.design_id, args.output)
        else:
            finalise(
                args.input_pdb,
                args.design_id,
                args.binder_msa,
                args.target_msa,
                args.output_dir,
            )
    except (OSError, ValueError) as exc:
        logging.error("OpenFold3 MSA: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
