#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Join the NIM and baseline pipelines' scores into one table for comparison.

The two pipelines name their outputs differently and each generates its own run
id, so nothing lines up on filename. They are matched on (design index,
replicate index), which both encode in the filename:

    NIM       design_ppi_<uid>_<design>_<replicate>.pdb
    baseline  design_ppi_<uid>_<design>_dldesign_0_mpnn<replicate>.pdb

They also report the same quantities under different column names, which are
normalised here. Designs that exist in only one pipeline are reported rather
than dropped silently: errorStrategy is 'ignore', so a design can fail on one
side and succeed on the other, and comparing the survivors without noticing
would bias the quality distribution.

Usage:
    benchmark_combine_arms.py --baseline <dir> --nim <dir> [-o combined.tsv]
"""

import argparse
import csv
import logging
import re
import sys
from pathlib import Path
from typing import Iterator, NamedTuple

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
log = logging.getLogger(__name__)

# The NIM pipeline's name for each quantity, mapped from the baseline's.
# plddt_binder, plddt_target and pae_interaction have no baseline equivalent:
# bin/openfold3_predict.py reports whole-complex confidence only.
COLUMN_ALIASES: dict[str, str] = {
    "avg_plddt": "plddt_complex",
    "complex_plddt_score": "plddt_complex",
    "ptm": "ptm",
    "ptm_score": "ptm",
    "iptm": "iptm",
    "iptm_score": "iptm",
    "gpde": "pde_complex",
    "complex_pde_score": "pde_complex",
}

BASELINE_ID = re.compile(r"_(?P<design>\d+)_dldesign_\d+_mpnn(?P<replicate>\d+)$")
NIM_ID = re.compile(r"_(?P<design>\d+)_(?P<replicate>\d+)$")


class DesignKey(NamedTuple):
    design: int
    replicate: int

    def __str__(self) -> str:
        return f"{self.design}/{self.replicate}"


def parse_design_key(description: str) -> DesignKey | None:
    """Pull (design, replicate) out of a design name, whichever pipeline wrote it."""
    stem = description.removesuffix(".pdb")
    for pattern in (BASELINE_ID, NIM_ID):
        match = pattern.search(stem)
        if match:
            return DesignKey(int(match["design"]), int(match["replicate"]))
    return None


def read_tsv_rows(path: Path) -> Iterator[dict[str, str]]:
    with path.open(newline="") as handle:
        yield from csv.DictReader(handle, delimiter="\t")


def collect_scores(root: Path, label: str) -> dict[DesignKey, dict[str, str]]:
    """Merge every TSV under root into one row per design, with aliases applied."""
    if not root.is_dir():
        raise SystemExit(f"{label}: not a directory: {root}")

    rows: dict[DesignKey, dict[str, str]] = {}
    unparsed: list[str] = []
    files = sorted(root.rglob("*.tsv"))
    if not files:
        raise SystemExit(f"{label}: no .tsv files under {root}")

    for path in files:
        for row in read_tsv_rows(path):
            description = row.get("description") or row.get("filename") or ""
            key = parse_design_key(description)
            if key is None:
                if description:
                    unparsed.append(description)
                continue
            merged = rows.setdefault(key, {"description": description})
            for column, value in row.items():
                if column in ("description", "filename"):
                    continue
                merged[COLUMN_ALIASES.get(column, column)] = value

    if unparsed:
        log.warning(
            "%s: %d row(s) had a description no pattern matched, e.g. %r",
            label,
            len(unparsed),
            unparsed[0],
        )
    log.info("%s: %d design(s) from %d file(s)", label, len(rows), len(files))
    return rows


def combine(
    baseline: dict[DesignKey, dict[str, str]],
    nim: dict[DesignKey, dict[str, str]],
) -> tuple[list[dict[str, str]], list[DesignKey], list[DesignKey]]:
    baseline_only = sorted(set(baseline) - set(nim))
    nim_only = sorted(set(nim) - set(baseline))
    shared = sorted(set(baseline) & set(nim))

    combined: list[dict[str, str]] = []
    for key in shared:
        row = {"design": str(key.design), "replicate": str(key.replicate)}
        for prefix, source in (("baseline", baseline[key]), ("nim", nim[key])):
            for column, value in source.items():
                row[f"{prefix}_{column}"] = value
        combined.append(row)
    return combined, baseline_only, nim_only


def write_tsv(rows: list[dict[str, str]], output: str) -> None:
    if not rows:
        raise SystemExit("no designs present in both pipelines - nothing to write")

    headers: list[str] = []
    for row in rows:
        for column in row:
            if column not in headers:
                headers.append(column)

    handle = sys.stdout if output == "-" else open(output, "w", newline="")
    try:
        writer = csv.DictWriter(handle, fieldnames=headers, delimiter="\t", restval="")
        writer.writeheader()
        writer.writerows(rows)
    finally:
        if handle is not sys.stdout:
            handle.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", type=Path, required=True, help="results directory for the baseline pipeline")
    parser.add_argument("--nim", type=Path, required=True, help="results directory for the NIM pipeline")
    parser.add_argument("-o", "--output", default="-", help="output TSV, or - for stdout [default: %(default)s]")
    args = parser.parse_args()

    baseline = collect_scores(args.baseline, "baseline")
    nim = collect_scores(args.nim, "nim")
    combined, baseline_only, nim_only = combine(baseline, nim)

    if baseline_only or nim_only:
        log.warning(
            "%d design(s) only in baseline (%s), %d only in NIM (%s) - excluded from the "
            "comparison, since a design that failed on one side would otherwise skew it",
            len(baseline_only),
            ", ".join(str(key) for key in baseline_only[:5]) or "-",
            len(nim_only),
            ", ".join(str(key) for key in nim_only[:5]) or "-",
        )

    log.info("%d design(s) present in both", len(combined))
    write_tsv(combined, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
