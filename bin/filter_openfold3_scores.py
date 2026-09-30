#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Filter one OpenFold3 complex using its normalised confidence scores."""

from typing import Sequence
import logging
import sys
import argparse
import csv
import io
import math
import operator
from pathlib import Path
import re
import shutil


MISSING_PAE = (
    "The deployed OpenFold3 NIM does not expose genuine PAE for this prediction, "
    "so pae_interaction cannot be evaluated. PDE/ipTM cannot substitute for PAE; "
    "the OpenFold3 integration is incomplete."
)
COMPARISONS = {
    "<=": operator.le,
    ">=": operator.ge,
    "==": operator.eq,
    "!=": operator.ne,
    ">": operator.gt,
    "<": operator.lt,
    "=": operator.eq,
}
FILTER_PATTERN = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*)\s*(<=|>=|==|!=|>|<|=)\s*"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
)
PASS_COLUMN = "openfold3_pass_filter"


def finite_number(value: str, label: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise ValueError(f"{label} must be numeric; received {value!r}.") from exc
    if not math.isfinite(number):
        raise ValueError(f"{label} must be finite; received {value!r}.")
    return number


def parse_filters(filters: str) -> list[tuple[str, str, float]]:
    parsed = []
    for expression in filters.split(";"):
        match = FILTER_PATTERN.fullmatch(expression.strip())
        if match is None:
            raise ValueError(f"Invalid numeric filter expression: {expression!r}.")
        metric, comparison, threshold = match.groups()
        parsed.append(
            (metric, comparison, finite_number(threshold, f"Threshold for {metric}"))
        )
    return parsed


def read_scores(scores_path: Path, pdb_path: Path) -> tuple[list[str], dict[str, str]]:
    with scores_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        columns = reader.fieldnames
        rows = list(reader)
    if not columns or any(not column for column in columns):
        raise ValueError("Scores must have a nonempty TSV header.")
    if len(columns) != len(set(columns)):
        raise ValueError("Scores contain duplicate column names.")
    if len(rows) != 1:
        raise ValueError(f"Expected exactly one design in scores; found {len(rows)}.")
    row = rows[0]
    if None in row or any(value is None for value in row.values()):
        raise ValueError("Scores row does not match the TSV header.")
    for column in ("description", "plddt_binder", "pae_interaction"):
        if column not in columns:
            if column == "pae_interaction":
                raise ValueError(MISSING_PAE)
            raise ValueError(f"Scores are missing required column {column!r}.")
    if row["description"] != pdb_path.stem:
        raise ValueError(
            f"Score description {row['description']!r} must equal "
            f"the predicted PDB stem {pdb_path.stem!r}."
        )
    for metric in ("plddt_binder", "plddt_target"):
        if metric in row and row[metric].strip():
            plddt = finite_number(row[metric], metric)
            if not 0 <= plddt <= 100:
                raise ValueError(f"{metric} must be on the 0–100 scale.")
    if row["pae_interaction"].strip():
        pae = finite_number(row["pae_interaction"], "pae_interaction")
        if pae < 0:
            raise ValueError("pae_interaction must be nonnegative, in angstroms.")
    return columns, row


def evaluate_filters(row: dict[str, str], filters: list[tuple[str, str, float]]) -> bool:
    values = {}
    for metric, _, _ in filters:
        if metric not in row:
            raise ValueError(f"Unknown filter metric {metric!r}.")
        if not row[metric].strip():
            if metric == "pae_interaction":
                raise ValueError(MISSING_PAE)
            raise ValueError(f"Requested metric {metric!r} is missing a value.")
        values[metric] = finite_number(row[metric], metric)

    # Validate every metric before testing, including those after a failing filter.
    return all(
        COMPARISONS[comparison](values[metric], threshold)
        for metric, comparison, threshold in filters
    )


def filter_scores(
    scores_path: Path,
    pdb_path: Path,
    filters: str,
    output: str,
    collect_in: Path,
) -> bool:
    parsed_filters = parse_filters(filters)
    if not pdb_path.is_file():
        raise ValueError(f"Predicted PDB does not exist: {pdb_path}.")
    columns, row = read_scores(scores_path, pdb_path)
    passed = evaluate_filters(row, parsed_filters)
    row[PASS_COLUMN] = str(passed)
    if PASS_COLUMN not in columns:
        columns.append(PASS_COLUMN)
    buffer = io.StringIO()
    writer = csv.DictWriter(
        buffer, fieldnames=columns, delimiter="\t", lineterminator="\n"
    )
    writer.writeheader()
    writer.writerow(row)

    destination = collect_in / ("accepted" if passed else "rejected") / pdb_path.name
    if output != "-" and Path(output).resolve() in (
        pdb_path.resolve(), destination.resolve()
    ):
        raise ValueError("The output TSV must not overwrite the predicted PDB.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.resolve() != pdb_path.resolve():
        shutil.copy2(pdb_path, destination)
    if output == "-":
        sys.stdout.write(buffer.getvalue())
    else:
        Path(output).write_text(buffer.getvalue(), encoding="utf-8")
    logging.info("%s: %s", pdb_path.stem, "accepted" if passed else "rejected")
    return passed


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scores", required=True, type=Path, help="Single-design scores TSV."
    )
    parser.add_argument("--pdb", required=True, type=Path, help="Predicted complex PDB.")
    parser.add_argument(
        "--filters", required=True,
        help="Semicolon-separated numeric filters; all comparisons must pass.",
    )
    parser.add_argument(
        "--output", default="-", help="Output TSV, or - for stdout (default)."
    )
    parser.add_argument(
        "--collect-in", required=True, type=Path,
        help="Copy the PDB into this directory's accepted/ or rejected/ subdirectory.",
    )
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.INFO, stream=sys.stderr, format="%(levelname)s: %(message)s"
    )
    try:
        filter_scores(args.scores, args.pdb, args.filters, args.output, args.collect_in)
    except (ValueError, OSError, csv.Error) as exc:
        logging.error("%s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
