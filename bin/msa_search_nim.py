#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# ///

"""
Query a locally-running MSA Search NIM (colabfold/msa-search) for MSA generation.

Drop-in replacement for colabfold_remote_msa.py: same --fasta/--output
interface and the same output naming, so openfold3_msa.py finalise consumes
either without change.

The NIM takes one sequence per request, so a multi-sequence FASTA becomes one
request per sequence.
"""

import argparse
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import List, Tuple

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
log = logging.getLogger(__name__)

DEFAULT_HOST = "http://localhost:8000"
PREDICT_PATH = "/biology/colabfold/msa-search/predict"
READY_PATH = "/v1/health/ready"
MERGED_KEY = "colabfold"


def read_fasta_sequences(path: Path) -> List[Tuple[str, str]]:
    """Return list of (header_line, sequence) from a FASTA file."""
    pairs: List[Tuple[str, str]] = []
    header = None
    seq: List[str] = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith(">"):
                if header is not None:
                    pairs.append((header, "".join(seq).replace(" ", "")))
                header = line
                seq = []
            else:
                seq.append(line)
        if header is not None:
            pairs.append((header, "".join(seq).replace(" ", "")))
    return pairs


def wait_until_ready(host: str, timeout_seconds: int) -> None:
    deadline = time.monotonic() + timeout_seconds
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            with urllib.request.urlopen(f"{host}{READY_PATH}", timeout=10) as res:
                if res.status == 200:
                    log.info("NIM ready after %d check(s)", attempt)
                    return
        except (urllib.error.URLError, OSError) as exc:
            log.info("Waiting for NIM (%d): %s", attempt, exc)
        time.sleep(10)
    raise TimeoutError(f"NIM at {host} did not become ready within {timeout_seconds}s")


def parse_a3m_records(alignment: str) -> List[Tuple[str, str]]:
    records: List[Tuple[str, str]] = []
    header = None
    seq: List[str] = []
    for line in alignment.splitlines():
        if line.startswith(">"):
            if header is not None:
                records.append((header, "".join(seq)))
            header = line
            seq = []
        elif line.strip():
            seq.append(line.strip())
    if header is not None:
        records.append((header, "".join(seq)))
    return records


def merge_alignments(alignments: dict, query: str, query_header: str) -> str:
    """Collapse the response's per-database A3Ms into one, query record first.

    search_type=colabfold returns a pre-merged "colabfold" entry; otherwise the
    per-database entries are concatenated and de-duplicated.
    """
    if MERGED_KEY in alignments:
        sources = [alignments[MERGED_KEY]]
    else:
        sources = list(alignments.values())

    records: List[Tuple[str, str]] = []
    for source in sources:
        a3m = source.get("a3m")
        if not a3m or not a3m.get("alignment"):
            continue
        records.extend(parse_a3m_records(a3m["alignment"]))

    hits: List[Tuple[str, str]] = []
    seen = set()
    for header, sequence in records:
        if sequence == query or sequence in seen:
            continue
        seen.add(sequence)
        hits.append((header, sequence))

    # openfold3_msa.py finalise requires the exact query as the first record.
    lines = [query_header, query]
    for header, sequence in hits:
        lines.extend([header, sequence])
    return "\n".join(lines) + "\n"


def search(host: str, payload: dict, timeout: int, retries: int, api_key: str = "") -> dict:
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    last_error = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            f"{host}{PREDICT_PATH}",
            data=data,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as res:
                return json.load(res)
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
            last_error = exc
            log.warning("MSA request failed (attempt %d/%d): %s", attempt, retries, exc)
            if attempt < retries:
                time.sleep(10 * attempt)
    raise RuntimeError(f"MSA search failed after {retries} attempts: {last_error}")


def resolve_output_paths(output: Path, fasta: Path, count: int) -> List[Path]:
    """Mirror colabfold_remote_msa.py naming so downstream globs keep working."""
    base = output if output.suffix else Path(output) / f"{fasta.stem}.a3m"
    base = Path(base)
    if count == 1:
        return [base]
    return [base.parent / f"{base.stem}_{i}{base.suffix}" for i in range(count)]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Query a local MSA Search NIM and write .a3m file(s)",
    )
    parser.add_argument("--fasta", required=True, type=Path, help="Input FASTA file")
    parser.add_argument(
        "-o", "--output", required=True, type=Path,
        help="Output path: file (single seq) or directory (multiple seqs)",
    )
    parser.add_argument(
        "--host", default=DEFAULT_HOST,
        help="Base URL: a local NIM, or https://health.api.nvidia.com/v1 for NVIDIA's "
             "hosted service [default: %(default)s]",
    )
    parser.add_argument(
        "--api-key-env", default="NVIDIA_API_KEY",
        help="Env var holding the bearer token; unset for a local NIM [default: %(default)s]",
    )
    parser.add_argument(
        "--databases", default="all",
        help="Comma-separated database names [default: %(default)s]",
    )
    parser.add_argument(
        "--search-type", default="colabfold", choices=("colabfold", "alphafold2"),
        help="[default: %(default)s]",
    )
    parser.add_argument("--e-value", type=float, default=0.0001, help="[default: %(default)s]")
    parser.add_argument("--iterations", type=int, default=1, help="[default: %(default)s]")
    parser.add_argument(
        "--max-msa-sequences", type=int, default=500,
        help="Max sequences per database [default: %(default)s]",
    )
    parser.add_argument(
        "--request-timeout", type=int, default=3600,
        help="Per-request timeout in seconds [default: %(default)s]",
    )
    parser.add_argument("--retries", type=int, default=3, help="[default: %(default)s]")
    parser.add_argument(
        "--wait-ready-seconds", type=int, default=0,
        help="Poll /v1/health/ready for this long before searching [default: %(default)s]",
    )
    args = parser.parse_args()

    if not args.fasta.exists():
        log.error("FASTA not found: %s", args.fasta)
        return 1

    pairs = read_fasta_sequences(args.fasta)
    if not pairs:
        log.error("No sequences found in %s", args.fasta)
        return 1

    host = args.host.rstrip("/")
    databases = [d.strip() for d in args.databases.split(",") if d.strip()]
    api_key = os.environ.get(args.api_key_env, "")

    try:
        if args.wait_ready_seconds > 0:
            wait_until_ready(host, args.wait_ready_seconds)

        alignments = []
        for index, (header, sequence) in enumerate(pairs):
            payload = {
                "sequence": sequence,
                "databases": databases,
                "e_value": args.e_value,
                "iterations": args.iterations,
                "search_type": args.search_type,
                "output_alignment_formats": ["a3m"],
                "max_msa_sequences": args.max_msa_sequences,
            }
            start = time.time()
            response = search(host, payload, args.request_timeout, args.retries, api_key)
            log.info(
                "Sequence %d/%d (%d aa) searched in %.1fs",
                index + 1, len(pairs), len(sequence), time.time() - start,
            )
            if "alignments" not in response:
                raise RuntimeError(f"Response has no alignments: {list(response)}")
            alignments.append(merge_alignments(response["alignments"], sequence, header))
    except (OSError, RuntimeError, TimeoutError, ValueError) as exc:
        log.error("MSA NIM search failed: %s", exc)
        return 1

    for path, content in zip(resolve_output_paths(args.output, args.fasta, len(pairs)), alignments):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        log.info("Wrote %s (%d records)", path, content.count(">"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
