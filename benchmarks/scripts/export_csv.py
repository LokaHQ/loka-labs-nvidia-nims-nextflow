#!/usr/bin/env python
"""Export benchmark results as tidy CSVs for plotting.

The other scripts in this directory print their findings to stdout. This one
writes the same underlying data in long form, one observation per row, so it
can be reloaded and plotted without re-running the analysis.

Stdlib only, for the same reason as the rest of the directory: the machine
that runs the analysis has no numpy or scipy.
"""
import argparse
import csv
import glob
import hashlib
import logging
import re
import statistics as st
import sys
from pathlib import Path
from typing import Any, Iterator, Optional, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kabsch import rmsd

log = logging.getLogger("export_csv")

# Hourly on-demand rate per Batch queue, used to turn task seconds into dollars.
RATES = {"nvidia-nims-gpu-standard": 2.240, "nvidia-nims-cpu-small": 0.384}
UNITS = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}

AA3 = {"ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q",
       "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K",
       "MET": "M", "PHE": "F", "PRO": "P", "SER": "S", "THR": "T", "TRP": "W",
       "TYR": "Y", "VAL": "V"}

# Each arm's OpenFold3 publishes the same quantities under different names.
SCORE_COLS = {
    "nonim": {"plddt": "avg_plddt", "ptm": "ptm", "iptm": "iptm", "pde": "gpde"},
    "nim": {"plddt": "complex_plddt_score", "ptm": "ptm_score",
            "iptm": "iptm_score", "pde": "complex_pde_score"},
}
BINDCRAFT_COLS = ["binder_score", "interface_dG", "interface_dSASA", "interface_sc",
                  "interface_packstat", "interface_nres", "interface_interface_hbonds",
                  "surface_hydrophobicity", "i_plddt", "ss_plddt", "unrelaxed_clashes"]

# Directory names differ per arm under <arm-dir>/rfd/.
OF3_DIR = {"nonim": "openfold3", "nim": "openfold3_nim"}
RELAXED_DIR = {"nonim": "proteinmpnn_relaxed", "nim": "proteinmpnn_nim_relaxed"}


def duration_seconds(text: str) -> Optional[float]:
    """Parse a Nextflow duration ('4m 7s', '161ms') into seconds.

    Returns None for '-' and other blanks. An aborted or failed task has no
    runtime, which is not the same as a runtime of zero: recording it as 0.0
    silently drags down any mean taken over the column.
    """
    text = (text or "").strip()
    if not text or text == "-":
        return None
    parts = re.findall(r"([0-9.]+)\s*(ms|h|m|s)", text)
    if not parts:
        return None
    return sum(float(n) * UNITS[u] for n, u in parts)


def design_index(path: str | Path) -> Optional[int]:
    m = re.match(r"design_ppi_[^_]+_(\d+)", Path(path).name)
    return int(m.group(1)) if m else None


def ca_atoms(path: Path, chain: Optional[str] = None) -> list[tuple[float, float, float]]:
    return [(float(l[30:38]), float(l[38:46]), float(l[46:54]))
            for l in path.read_text().splitlines()
            if l.startswith("ATOM") and l[12:16].strip() == "CA"
            and (chain is None or l[21] == chain)]


def ca_bfactors(path: Path, chain: str) -> list[float]:
    return [float(l[60:66]) for l in path.read_text().splitlines()
            if l.startswith("ATOM") and l[12:16].strip() == "CA" and l[21] == chain]


def chain_sequence(path: Path, chain: str = "A") -> str:
    seq, seen = "", set()
    for l in path.read_text().splitlines():
        if l.startswith("ATOM") and l[21] == chain:
            rid = l[22:27]
            if rid not in seen:
                seen.add(rid)
                seq += AA3.get(l[17:20].strip(), "X")
    return seq


def pair_rmsd(a: Sequence, b: Sequence) -> Optional[float]:
    n = min(len(a), len(b))
    return rmsd(list(a[:n]), list(b[:n])) if n > 3 else None


def as_float(row: Optional[dict], key: str) -> Optional[float]:
    if not row:
        return None
    try:
        return float(row[key])
    except (KeyError, TypeError, ValueError):
        return None


def write_csv(path: Optional[str], fields: list[str], rows: list[dict],
              append: bool = False) -> None:
    """Write rows to path, or to stdout when path is '-' or None."""
    if path in (None, "-"):
        w = csv.DictWriter(sys.stdout, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    exists = append and target.exists() and target.stat().st_size > 0
    with target.open("a" if append else "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        if not exists:
            w.writeheader()
        w.writerows(rows)
    log.info("wrote %d rows to %s", len(rows), target)


# --- tasks ------------------------------------------------------------------

TASK_FIELDS = ["run_id", "arm", "process", "task_name", "task_index", "status",
               "exit", "realtime_s", "queue", "cpu_pct", "peak_rss_mb", "cost_usd"]


def read_trace(path: Path) -> Iterator[dict[str, str]]:
    with path.open() as fh:
        yield from csv.DictReader(fh, delimiter="\t")


def read_nextflow_log(path: Path, fields: Sequence[str]) -> Iterator[dict[str, str]]:
    """Read headerless `nextflow log <run> -f ...` output with known columns."""
    with path.open() as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            yield dict(zip(fields, line.split("\t")))


def to_mb(text: str) -> Optional[float]:
    text = (text or "").strip()
    m = re.match(r"([0-9.]+)\s*([KMGT]?)B?", text, re.I)
    if not m:
        return None
    scale = {"": 1 / 1048576, "K": 1 / 1024, "M": 1.0, "G": 1024.0, "T": 1048576.0}
    return float(m.group(1)) * scale.get(m.group(2).upper(), 1.0)


def cmd_tasks(args: argparse.Namespace) -> None:
    src = Path(args.input)
    if args.fields:
        records = read_nextflow_log(src, args.fields.split(","))
    else:
        records = read_trace(src)

    rows = []
    for r in records:
        name = r.get("name", "")
        process = name.split(":")[-1].split(" (")[0]
        m = re.search(r"\((\d+)\)\s*$", name)
        queue = r.get("queue") or args.queue or ""
        secs = duration_seconds(r.get("realtime", ""))
        rows.append({
            "run_id": args.run_id,
            "arm": args.arm,
            "process": process,
            "task_name": name,
            "task_index": int(m.group(1)) if m else "",
            "status": r.get("status", ""),
            "exit": r.get("exit", ""),
            "realtime_s": round(secs, 3) if secs is not None else "",
            "queue": queue,
            "cpu_pct": (r.get("%cpu") or "").rstrip("%"),
            "peak_rss_mb": to_mb(r.get("peak_rss", "")) or "",
            "cost_usd": (round(secs / 3600.0 * RATES.get(queue, 0.0), 6)
                         if secs is not None else ""),
        })
    write_csv(args.output, TASK_FIELDS, rows, args.append)


# --- designs ----------------------------------------------------------------

DESIGN_FIELDS = (["run_id", "arm", "design_index", "binder_len", "backbone_sha256",
                  "sequence", "plddt", "ptm", "iptm", "pde", "plddt_binder",
                  "plddt_target", "selfcon_rmsd_a"] + BINDCRAFT_COLS)


def load_arm(base: Path, arm: str) -> dict[str, Any]:
    """Collect every per-design file an arm publishes, keyed by design index."""
    of3, rel = OF3_DIR[arm], RELAXED_DIR[arm]
    data = {
        "backbone": {design_index(f): Path(f)
                     for f in glob.glob(f"{base}/rfdiffusion/pdbs/*.pdb")},
        "fold": {design_index(f): Path(f)
                 for f in glob.glob(f"{base}/{of3}/pdbs/*.pdb")},
        "relaxed": {design_index(f): Path(f) for f in glob.glob(f"{base}/{rel}/*.pdb")},
        "scores": tsv_by_index(f"{base}/{of3}/scores"),
        "extra": tsv_by_index(f"{base}/{of3}/extra_scores"),
    }
    for key in ("backbone", "fold", "relaxed"):
        data[key].pop(None, None)
    log.info("%s: %d backbones, %d folds, %d scores, %d bindcraft", arm,
             len(data["backbone"]), len(data["fold"]),
             len(data["scores"]), len(data["extra"]))
    return data


def tsv_by_index(directory: str) -> dict[int, dict[str, str]]:
    out = {}
    for f in glob.glob(f"{directory}/*.tsv"):
        i = design_index(f)
        if i is None:
            continue
        with open(f) as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))
        if rows:
            out[i] = rows[0]
    return out


def design_rows(run_id: str, arm: str, data: dict[str, Any]) -> list[dict]:
    cols = SCORE_COLS[arm]
    rows = []
    for i in sorted(data["backbone"]):
        bb, fold = data["backbone"][i], data["fold"].get(i)
        relaxed = data["relaxed"].get(i)
        score, extra = data["scores"].get(i), data["extra"].get(i)
        binder_ca = ca_atoms(bb, "A")
        digest = hashlib.sha256(
            "".join(f"{x:.3f},{y:.3f},{z:.3f};" for x, y, z in ca_atoms(bb)).encode()
        ).hexdigest()
        row = {
            "run_id": run_id,
            "arm": arm,
            "design_index": i,
            "binder_len": len(binder_ca),
            "backbone_sha256": digest,
            "sequence": chain_sequence(relaxed) if relaxed else "",
            "plddt": as_float(score, cols["plddt"]),
            "ptm": as_float(score, cols["ptm"]),
            "iptm": as_float(score, cols["iptm"]),
            "pde": as_float(score, cols["pde"]),
        }
        if fold:
            for chain, key in (("A", "plddt_binder"), ("B", "plddt_target")):
                b = ca_bfactors(fold, chain)
                row[key] = round(st.mean(b), 3) if b else None
            r = pair_rmsd(binder_ca, ca_atoms(fold, "A"))
            row["selfcon_rmsd_a"] = round(r, 4) if r is not None else None
        for c in BINDCRAFT_COLS:
            row[c] = as_float(extra, c)
        rows.append(row)
    return rows


def cmd_designs(args: argparse.Namespace) -> None:
    rows = []
    for arm, base in (("nonim", args.nonim), ("nim", args.nim)):
        if base:
            rows += design_rows(args.run_id, arm, load_arm(Path(base) / "rfd", arm))
    write_csv(args.output, DESIGN_FIELDS, rows, args.append)


# --- pairs ------------------------------------------------------------------

PAIR_FIELDS = ["run_id", "design_index", "backbone_identical", "seq_identity_pct",
               "cross_arm_fold_rmsd_a", "plddt_nonim", "plddt_nim",
               "iptm_nonim", "iptm_nim", "binder_score_nonim", "binder_score_nim",
               "binder_score_diff"]


def cmd_pairs(args: argparse.Namespace) -> None:
    arms = {a: load_arm(Path(d) / "rfd", a)
            for a, d in (("nonim", args.nonim), ("nim", args.nim))}
    shared = sorted(set(arms["nonim"]["backbone"]) & set(arms["nim"]["backbone"]))
    rows = []
    for i in shared:
        s1 = chain_sequence(arms["nonim"]["relaxed"][i]) if i in arms["nonim"]["relaxed"] else ""
        s2 = chain_sequence(arms["nim"]["relaxed"][i]) if i in arms["nim"]["relaxed"] else ""
        identity = None
        if s1 and s2 and len(s1) == len(s2):
            identity = round(100.0 * sum(a == b for a, b in zip(s1, s2)) / len(s1), 3)

        sha = {a: hashlib.sha256(
            "".join(f"{x:.3f},{y:.3f},{z:.3f};" for x, y, z in
                    ca_atoms(arms[a]["backbone"][i])).encode()).hexdigest() for a in arms}

        cross = None
        if i in arms["nonim"]["fold"] and i in arms["nim"]["fold"]:
            r = pair_rmsd(ca_atoms(arms["nonim"]["fold"][i], "A"),
                          ca_atoms(arms["nim"]["fold"][i], "A"))
            cross = round(r, 4) if r is not None else None

        bs = {a: as_float(arms[a]["extra"].get(i), "binder_score") for a in arms}
        row = {
            "run_id": args.run_id,
            "design_index": i,
            "backbone_identical": sha["nonim"] == sha["nim"],
            "seq_identity_pct": identity,
            "cross_arm_fold_rmsd_a": cross,
            "binder_score_nonim": bs["nonim"],
            "binder_score_nim": bs["nim"],
            "binder_score_diff": (round(bs["nim"] - bs["nonim"], 4)
                                  if bs["nim"] is not None and bs["nonim"] is not None
                                  else None),
        }
        for a in arms:
            sc = arms[a]["scores"].get(i)
            row[f"plddt_{a}"] = as_float(sc, SCORE_COLS[a]["plddt"])
            row[f"iptm_{a}"] = as_float(sc, SCORE_COLS[a]["iptm"])
        rows.append(row)
    write_csv(args.output, PAIR_FIELDS, rows, args.append)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--run-id", required=True, help="label for this run, e.g. n150")
    common.add_argument("-o", "--output", default="-", help="CSV path, or - for stdout")
    common.add_argument("--append", action="store_true",
                        help="append to an existing CSV instead of replacing it")

    t = sub.add_parser("tasks", parents=[common],
                       help="per-task time and cost from a trace or nextflow log")
    t.add_argument("input", help="Nextflow trace .txt, or `nextflow log` output")
    t.add_argument("--arm", required=True)
    t.add_argument("--fields", help="comma-separated columns, if input is headerless "
                                    "`nextflow log -f` output")
    t.add_argument("--queue", help="queue name, when the input has no queue column")
    t.set_defaults(func=cmd_tasks)

    d = sub.add_parser("designs", parents=[common],
                       help="per-design confidence, quality and self-consistency")
    d.add_argument("--nonim", help="open-source arm directory")
    d.add_argument("--nim", help="NIM arm directory")
    d.set_defaults(func=cmd_designs)

    q = sub.add_parser("pairs", parents=[common],
                       help="matched per-design comparison between the two arms")
    q.add_argument("--nonim", required=True)
    q.add_argument("--nim", required=True)
    q.set_defaults(func=cmd_pairs)

    args = p.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(message)s", stream=sys.stderr)
    args.func(args)


if __name__ == "__main__":
    main()
