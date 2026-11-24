import json, os, sys, csv, re, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kabsch import rmsd
BENCH, V16, DESIGNS, OUT = sys.argv[1:5]
def ca_txt(txt):
    ch = {}
    for ln in txt.splitlines():
        if ln.startswith("ATOM") and ln[12:16].strip() == "CA":
            ch.setdefault(ln[21], []).append((float(ln[30:38]), float(ln[38:46]), float(ln[46:54])))
    return ch
bench = {f[:-4]: ca_txt(open(os.path.join(BENCH, f)).read())
         for f in os.listdir(BENCH) if f.endswith(".pdb")}
v16 = {}
for f in os.listdir(V16):
    if not f.endswith(".resp.json"): continue
    s = json.load(open(os.path.join(V16, f)))["outputs"][0]["structures_with_scores"][0]
    v16[f[:-len(".resp.json")]] = (ca_txt(s["structure"]), s["iptm_score"], s["complex_plddt_score"])
d150 = {r["design_index"]: r for r in csv.DictReader(open(DESIGNS))
        if r["run_id"] == "n150" and r["arm"] == "nim"}
rows = []
for k in sorted(set(bench) & set(v16), key=lambda s: int(re.search(r"_(\d+)_0$", s).group(1))):
    idx = re.search(r"_(\d+)_0$", k).group(1)
    c1 = bench[k]; c2, ip2, pl2 = v16[k]
    ref = d150.get(idx)
    rows.append({
        "run_id": "n150",
        "design_index": idx,
        "design_id": k,
        "binder_rmsd_a": round(rmsd(c1["A"], c2["A"]), 3),
        "target_rmsd_a": round(rmsd(c1["B"], c2["B"]), 3),
        "complex_rmsd_a": round(rmsd(c1["A"] + c1["B"], c2["A"] + c2["B"]), 3),
        "iptm_150": ref["iptm"] if ref else "",
        "iptm_160": round(ip2, 4),
        "complex_plddt_150": ref["plddt"] if ref else "",
        "complex_plddt_160": round(pl2, 2),
    })
with open(OUT, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
b = [r["binder_rmsd_a"] for r in rows]; c = [r["complex_rmsd_a"] for r in rows]; t = [r["target_rmsd_a"] for r in rows]
print("rows:", len(rows))
print("binder  <=2 A:", sum(1 for x in b if x <= 2), "(post 89)")
print("complex <=2 A:", sum(1 for x in c if x <= 2), "(post 46)")
print("target median: %.2f A (post 0.3)" % statistics.median(t))
print("identical predictions:", sum(1 for x in b if x == 0), "(post none)")
t1 = {r["design_index"] for r in sorted(rows, key=lambda r: -float(r["iptm_150"]))[:20]}
t2 = {r["design_index"] for r in sorted(rows, key=lambda r: -float(r["iptm_160"]))[:20]}
print("top 20 by ipTM shared:", len(t1 & t2), "(post 13)")
