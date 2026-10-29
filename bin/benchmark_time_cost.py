#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Per-stage time and cost for each pipeline, from Nextflow trace files.

Reports, per process, the task count, total and median task time, and an
estimated cost. Cost is derived from the QUEUE the task ran on, not from the
instance it actually landed on: AWS Batch chooses the instance and nothing in
the pipeline records which one. A 2-vCPU job has been observed landing on a
g6e.4xlarge, so these figures are an approximation whose direction is unknown.
Treat them as a ratio between the pipelines rather than an absolute.

Two further caveats the numbers cannot show:
  - A self-hosted MSA Search NIM is billed for as long as its task holds the
    instance, which is in the trace. A standing server would not be.
  - Retries are counted, so a design that succeeded on its third attempt costs
    what all three attempts cost. That is the honest figure.

Usage:
    benchmark_time_cost.py --baseline <trace.txt> --nim <trace.txt> [-o out.tsv]
"""

import argparse
import csv
import logging
import statistics
import sys
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
log = logging.getLogger(__name__)

# us-east-1 on-demand, 2026-10. Spot is cheaper and variable; using on-demand
# keeps the comparison between pipelines stable and is an upper bound.
QUEUE_HOURLY_USD: dict[str, float] = {
    "nvidia-nims-gpu-standard": 2.24,   # g6e.2xlarge
    "nvidia-nims-gpu-highmem": 10.49,   # g6e.12xlarge
    "nvidia-nims-cpu-small": 0.384,     # m5.2xlarge
}
DEFAULT_HOURLY_USD = 2.24


def parse_duration_ms(value: str) -> float | None:
    """Nextflow writes durations as '1m 37s', '950ms', '2h 3m 4s' or bare ms."""
    value = (value or "").strip()
    if not value or value == "-":
        return None
    if value.replace(".", "", 1).isdigit():
        return float(value)
    units = {"h": 3_600_000.0, "m": 60_000.0, "s": 1_000.0, "ms": 1.0}
    total = 0.0
    matched = False
    for token in value.split():
        for suffix in ("ms", "h", "m", "s"):
            if token.endswith(suffix):
                number = token[: -len(suffix)]
                try:
                    total += float(number) * units[suffix]
                except ValueError:
                    continue
                matched = True
                break
    return total if matched else None


def summarise(trace_path: Path, label: str) -> list[dict[str, str]]:
    if not trace_path.is_file():
        raise SystemExit(f"{label}: no such trace file: {trace_path}")

    by_process: dict[str, list[tuple[float, str, str]]] = {}
    with trace_path.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if "realtime" not in (reader.fieldnames or []):
            raise SystemExit(
                f"{label}: trace has no 'realtime' column. Fields present: {reader.fieldnames}"
            )
        for row in reader:
            process = (row.get("name") or "").split(" (")[0]
            realtime = parse_duration_ms(row.get("realtime", ""))
            if not process or realtime is None:
                continue
            by_process.setdefault(process, []).append(
                (realtime, row.get("queue", ""), row.get("status", ""))
            )

    rows = []
    for process, entries in sorted(by_process.items()):
        times = [entry[0] for entry in entries]
        queue = next((entry[1] for entry in entries if entry[1]), "")
        failed = sum(1 for entry in entries if entry[2] not in ("COMPLETED", "CACHED"))
        rate = QUEUE_HOURLY_USD.get(queue, DEFAULT_HOURLY_USD)
        total_hours = sum(times) / 3_600_000.0
        rows.append({
            "pipeline": label,
            "process": process,
            "tasks": str(len(times)),
            "failed_tasks": str(failed),
            "queue": queue or "unknown",
            "total_seconds": f"{sum(times) / 1000:.1f}",
            "median_seconds": f"{statistics.median(times) / 1000:.1f}",
            "usd_per_hour": f"{rate:.3f}",
            "estimated_usd": f"{total_hours * rate:.4f}",
        })
    log.info("%s: %d process(es), %d task(s)", label, len(rows), sum(int(r["tasks"]) for r in rows))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", type=Path, required=True, help="baseline pipeline trace file")
    parser.add_argument("--nim", type=Path, required=True, help="NIM pipeline trace file")
    parser.add_argument("-o", "--output", default="-")
    args = parser.parse_args()

    rows = summarise(args.baseline, "baseline") + summarise(args.nim, "nim")
    if not rows:
        raise SystemExit("no tasks found in either trace")

    handle = sys.stdout if args.output == "-" else open(args.output, "w", newline="")
    try:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    finally:
        if handle is not sys.stdout:
            handle.close()

    for label in ("baseline", "nim"):
        subset = [row for row in rows if row["pipeline"] == label]
        total_usd = sum(float(row["estimated_usd"]) for row in subset)
        total_s = sum(float(row["total_seconds"]) for row in subset)
        log.info("%s: %.1f task-seconds, ~$%.2f estimated", label, total_s, total_usd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
