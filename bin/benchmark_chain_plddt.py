#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Per-chain pLDDT for both benchmark arms, read from PDB B-factors.

bin/openfold3_predict.py writes whole-complex confidence only, so
plddt_binder and plddt_target have no baseline column. Both arms do write
per-residue pLDDT into the B-factor field of the published structure, so the
per-chain means can be recovered without rerunning either pipeline.

CA atoms only, so a residue counts once whatever its side chain size.

    benchmark_chain_plddt.py results/*/rfd/openfold3*/pdbs/*.pdb -o chain_plddt.tsv
"""

import argparse
import logging
import sys
from pathlib import Path
from typing import Iterator

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
log = logging.getLogger(__name__)


def ca_plddt_by_chain(pdb_path: Path) -> dict[str, list[float]]:
    """Map chain ID to its CA B-factors, which OpenFold3 writes as pLDDT."""
    by_chain: dict[str, list[float]] = {}
    for line in pdb_path.read_text().splitlines():
        if not line.startswith("ATOM") or line[12:16].strip() != "CA":
            continue
        try:
            by_chain.setdefault(line[21], []).append(float(line[60:66]))
        except ValueError:
            log.warning("%s: unparseable B-factor, skipping line", pdb_path.name)
    return by_chain


def rows(pdb_paths: list[Path], binder: str, target: str) -> Iterator[dict[str, object]]:
    for pdb_path in pdb_paths:
        by_chain = ca_plddt_by_chain(pdb_path)
        missing = [c for c in (binder, target) if c not in by_chain]
        if missing:
            log.warning("%s: no chain %s, skipping", pdb_path.name, ",".join(missing))
            continue
        row: dict[str, object] = {"description": pdb_path.stem}
        for label, chain in (("binder", binder), ("target", target)):
            values = by_chain[chain]
            row[f"plddt_{label}"] = round(sum(values) / len(values), 2)
            row[f"residues_{label}"] = len(values)
        yield row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pdbs", nargs="+", type=Path, help="Predicted complexes from either arm")
    parser.add_argument("-o", "--output", default="-", help="Output TSV, or - for stdout")
    parser.add_argument("--binder-chain", default="A")
    parser.add_argument("--target-chain", default="B")
    args = parser.parse_args()

    collected = list(rows(args.pdbs, args.binder_chain, args.target_chain))
    if not collected:
        sys.exit("No structure yielded both chains")

    handle = sys.stdout if args.output == "-" else open(args.output, "w")
    try:
        columns = list(collected[0])
        print("\t".join(columns), file=handle)
        for row in collected:
            print("\t".join(str(row[c]) for c in columns), file=handle)
    finally:
        if handle is not sys.stdout:
            handle.close()
    log.info("Wrote %d structures to %s", len(collected), args.output)


if __name__ == "__main__":
    main()
