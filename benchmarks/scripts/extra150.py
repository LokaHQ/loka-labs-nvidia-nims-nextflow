#!/usr/bin/env python
"""Metrics the N=150 doc is missing relative to the 5-binder doc."""
import csv, glob, json, math, os, re, statistics as st, sys
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kabsch import rmsd

SP = os.path.dirname(os.path.abspath(__file__))
ARMS = {'nonim': f'{SP}/n150a', 'nim': f'{SP}/a2'}
OF3 = {'nonim': 'openfold3', 'nim': 'openfold3_nim'}
REL = {'nonim': 'proteinmpnn_relaxed', 'nim': 'proteinmpnn_nim_relaxed'}
AA3 = {"ALA":"A","ARG":"R","ASN":"N","ASP":"D","CYS":"C","GLN":"Q","GLU":"E","GLY":"G",
       "HIS":"H","ILE":"I","LEU":"L","LYS":"K","MET":"M","PHE":"F","PRO":"P","SER":"S",
       "THR":"T","TRP":"W","TYR":"Y","VAL":"V"}
FULLNAME = {"A":"Alanine","R":"Arginine","N":"Asparagine","D":"Aspartate","C":"Cysteine",
            "Q":"Glutamine","E":"Glutamate","G":"Glycine","H":"Histidine","I":"Isoleucine",
            "L":"Leucine","K":"Lysine","M":"Methionine","F":"Phenylalanine","P":"Proline",
            "S":"Serine","T":"Threonine","W":"Tryptophan","Y":"Tyrosine","V":"Valine"}

def idx(p):
    m = re.match(r'design_ppi_[^_]+_(\d+)', Path(p).name)
    return int(m.group(1)) if m else None

def ca(path, chain=None):
    return [(float(l[30:38]), float(l[38:46]), float(l[46:54]))
            for l in Path(path).read_text().splitlines()
            if l.startswith('ATOM') and l[12:16].strip() == 'CA' and (not chain or l[21] == chain)]

def seq(path, chain='A'):
    s, seen = '', set()
    for l in Path(path).read_text().splitlines():
        if l.startswith('ATOM') and l[21] == chain:
            if l[22:27] not in seen:
                seen.add(l[22:27]); s += AA3.get(l[17:20].strip(), 'X')
    return s

def rows(d):
    out = {}
    for f in glob.glob(f'{d}/*.tsv'):
        with open(f) as fh:
            r = list(csv.DictReader(fh, delimiter='\t'))
        if r:
            out[idx(f)] = r[0]
    return out

D = {}
for arm, base in ARMS.items():
    D[arm] = {
        'bb':   {idx(f): f for f in glob.glob(f'{base}/rfdiffusion/pdbs/*.pdb')},
        'fold': {idx(f): f for f in glob.glob(f'{base}/{OF3[arm]}/pdbs/*.pdb')},
        'rel':  {idx(f): f for f in glob.glob(f'{base}/{REL[arm]}/*.pdb')},
        'sc':   rows(f'{base}/{OF3[arm]}/scores'),
        'ex':   rows(f'{base}/{OF3[arm]}/extra_scores'),
    }
ids = sorted(set(D['nonim']['fold']) & set(D['nim']['fold']))
out = {}

# ---- 1. cross-arm fold agreement -------------------------------------------
cross, sc_a, sc_b, seqid = {}, {}, {}, {}
for i in ids:
    x, y = ca(D['nonim']['fold'][i], 'A'), ca(D['nim']['fold'][i], 'A')
    n = min(len(x), len(y))
    if n > 3:
        cross[i] = rmsd(x[:n], y[:n])
    b = ca(D['nonim']['bb'][i], 'A')
    for arm, store in (('nonim', sc_a), ('nim', sc_b)):
        f = ca(D[arm]['fold'][i], 'A')
        m = min(len(b), len(f))
        store[i] = rmsd(b[:m], f[:m])
    s1, s2 = seq(D['nonim']['rel'][i]), seq(D['nim']['rel'][i])
    if len(s1) == len(s2) and s1:
        seqid[i] = 100.0 * sum(c == d for c, d in zip(s1, s2)) / len(s1)

def dist(v):
    v = sorted(v)
    return dict(n=len(v), mean=st.mean(v), median=st.median(v),
                p25=v[len(v)//4], p75=v[3*len(v)//4], mn=v[0], mx=v[-1])

out['cross_arm_fold_rmsd'] = dist(cross.values())
out['agree_under_2A'] = sum(1 for v in cross.values() if v < 2.0)
out['agree_under_1_8A'] = sum(1 for v in cross.values() if v < 1.8)
out['seq_identity'] = dist(seqid.values())
out['selfcon'] = {'nonim': dist(sc_a.values()), 'nim': dist(sc_b.values())}
both_ok = sum(1 for i in ids if sc_a[i] < 10 and sc_b[i] < 10)
both_bad = sum(1 for i in ids if sc_a[i] > 10 and sc_b[i] > 10)
out['selfcon_concordance'] = {'both_pass': both_ok, 'both_fail': both_bad,
                              'disagree': len(ids) - both_ok - both_bad}

# ---- 2. amino-acid composition ---------------------------------------------
comp = {}
for arm in ARMS:
    c = {}
    for i in ids:
        for ch in seq(D[arm]['rel'][i]):
            c[ch] = c.get(ch, 0) + 1
    comp[arm] = c
letters = sorted(set(comp['nonim']) | set(comp['nim']),
                 key=lambda k: -abs(comp['nim'].get(k, 0) - comp['nonim'].get(k, 0)))
out['aa'] = [{'aa': FULLNAME.get(k, k), 'nonim': comp['nonim'].get(k, 0),
              'nim': comp['nim'].get(k, 0),
              'diff': comp['nim'].get(k, 0) - comp['nonim'].get(k, 0)} for k in letters]
out['aa_total'] = {a: sum(comp[a].values()) for a in ARMS}

# ---- 3. paired Wilcoxon signed-rank on every metric ------------------------
def wilcoxon(d):
    d = [x for x in d if x != 0]
    n = len(d)
    if n < 10:
        return None
    order = sorted(range(n), key=lambda k: abs(d[k]))
    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and abs(d[order[j + 1]]) == abs(d[order[i]]):
            j += 1
        r = (i + j) / 2.0 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = r
        i = j + 1
    wp = sum(r for r, x in zip(ranks, d) if x > 0)
    wm = sum(r for r, x in zip(ranks, d) if x < 0)
    W = min(wp, wm)
    mu = n * (n + 1) / 4.0
    tie = {}
    for r in ranks:
        tie[r] = tie.get(r, 0) + 1
    corr = sum(t ** 3 - t for t in tie.values()) / 48.0
    sd = math.sqrt(n * (n + 1) * (2 * n + 1) / 24.0 - corr)
    z = (W - mu + 0.5) / sd
    p = 2 * (1 - 0.5 * (1 + math.erf(abs(z) / math.sqrt(2))))
    return {'W': W, 'z': z, 'p': min(p, 1.0), 'n': n}

SCORE = [('complex_plddt_score', 'avg_plddt', 'pLDDT (complex)', 'up'),
         ('ptm_score', 'ptm', 'ptm', 'up'),
         ('iptm_score', 'iptm', 'iptm', 'up'),
         ('complex_pde_score', 'gpde', 'pde', 'down')]
EXTRA = [('binder_score', 'binder_score', 'down'),
         ('interface_dG', 'interface_dG', 'down'),
         ('interface_dSASA', 'interface_dSASA', 'up'),
         ('interface_dG_SASA_ratio', 'interface_dG_SASA_ratio', 'down'),
         ('interface_sc', 'interface_sc', 'up'),
         ('interface_packstat', 'interface_packstat', 'up'),
         ('interface_nres', 'interface_nres', 'up'),
         ('interface_interface_hbonds', 'interface_hbonds', 'up'),
         ('interface_hbond_percentage', 'interface_hbond_percentage', 'up'),
         ('interface_delta_unsat_hbonds', 'delta_unsat_hbonds', 'down'),
         ('interface_fraction', 'interface_fraction', 'up'),
         ('interface_hydrophobicity', 'interface_hydrophobicity', 'none'),
         ('surface_hydrophobicity', 'surface_hydrophobicity', 'down'),
         ('i_plddt', 'i_plddt', 'up'),
         ('ss_plddt', 'ss_plddt', 'up'),
         ('unrelaxed_clashes', 'unrelaxed_clashes', 'down'),
         ('relaxed_clashes', 'relaxed_clashes', 'down'),
         ('binder_helix%', 'binder_helix%', 'none'),
         ('binder_betasheet%', 'binder_betasheet%', 'none'),
         ('binder_loop%', 'binder_loop%', 'none')]

tests = []
def add(label, a, b, direction):
    pair = [(x, y) for x, y in zip(a, b) if x is not None and y is not None]
    if len(pair) < 10:
        return
    d = [y - x for x, y in pair]
    w = wilcoxon(d)
    if w is None:   # fewer than 10 non-zero differences: no usable test
        w = {'z': 0.0, 'p': 1.0, 'n': sum(1 for x in d if x != 0)}
    ma, mb = st.mean([x for x, _ in pair]), st.mean([y for _, y in pair])
    sda, sdb = st.pstdev([x for x, _ in pair]), st.pstdev([y for _, y in pair])
    if direction == 'none':
        fav = '—'
    elif ma == mb:
        fav = 'tie'
    else:
        better_is_nim = (mb > ma) if direction == 'up' else (mb < ma)
        fav = 'NIM' if better_is_nim else 'no-NIM'
    tests.append({'metric': label, 'nonim': ma, 'nim': mb, 'sd_nonim': sda, 'sd_nim': sdb,
                  'z': w['z'], 'p': w['p'], 'n': w['n'], 'favours': fav, 'dir': direction})

def getf(r, k):
    v = r.get(k) if r else None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

for knim, knon, label, d in SCORE:
    add(label, [getf(D['nonim']['sc'].get(i), knon) for i in ids],
        [getf(D['nim']['sc'].get(i), knim) for i in ids], d)
# per-chain pLDDT comes from the score files on the NIM side only, so use B-factors
def bfac(path, chain):
    v = [float(l[60:66]) for l in Path(path).read_text().splitlines()
         if l.startswith('ATOM') and l[12:16].strip() == 'CA' and l[21] == chain]
    return st.mean(v) if v else None
for chain, label in (('A', 'plddt_binder'), ('B', 'plddt_target')):
    add(label, [bfac(D['nonim']['fold'][i], chain) for i in ids],
        [bfac(D['nim']['fold'][i], chain) for i in ids], 'up')
for key, label, d in EXTRA:
    add(label, [getf(D['nonim']['ex'].get(i), key) for i in ids],
        [getf(D['nim']['ex'].get(i), key) for i in ids], d)

# Benjamini-Hochberg across the whole family
m = len(tests)
for rank, t in enumerate(sorted(tests, key=lambda t: t['p']), 1):
    t['q'] = min(1.0, t['p'] * m / rank)
run_min = 1.0
for t in sorted(tests, key=lambda t: -t['p']):
    run_min = min(run_min, t['q'])
    t['q'] = run_min
tests.sort(key=lambda t: t['p'])
out['tests'] = tests
out['n_tests'] = m
out['n_sig_raw'] = sum(1 for t in tests if t['p'] < 0.05)
out['n_sig_bh'] = sum(1 for t in tests if t['q'] < 0.05)
out['n_favour_nim'] = sum(1 for t in tests if t['favours'] == 'NIM')
out['n_favour_nonim'] = sum(1 for t in tests if t['favours'] == 'no-NIM')

# ---- 4. NIM-only score fields ----------------------------------------------
out['nim_only'] = {k: dist([getf(D['nim']['sc'][i], k) for i in ids
                            if getf(D['nim']['sc'].get(i), k) is not None])
                   for k in ('pae_interaction', 'confidence_score')}

json.dump(out, open(f'{SP}/extra150.json', 'w'), indent=1, default=float)

print(f"cross-arm fold RMSD: median {out['cross_arm_fold_rmsd']['median']:.2f} A, "
      f"mean {out['cross_arm_fold_rmsd']['mean']:.2f}, "
      f"<2A: {out['agree_under_2A']}/{len(ids)}")
print(f"seq identity: median {out['seq_identity']['median']:.1f}% "
      f"range {out['seq_identity']['mn']:.1f}-{out['seq_identity']['mx']:.1f}")
print(f"self-consistency concordance: {out['selfcon_concordance']}")
print(f"\ntests={m} sig(raw)={out['n_sig_raw']} sig(BH)={out['n_sig_bh']} "
      f"favour NIM={out['n_favour_nim']} favour no-NIM={out['n_favour_nonim']}")
print(f"{'metric':28s} {'no-NIM':>10s} {'NIM':>10s} {'p':>9s} {'q':>8s}  favours")
for t in tests:
    print(f"{t['metric']:28s} {t['nonim']:10.3f} {t['nim']:10.3f} {t['p']:9.2e} {t['q']:8.3f}  {t['favours']}")
print('\nNIM-only:', {k: round(v['mean'], 3) for k, v in out['nim_only'].items()})
print('\nAA composition (top shifts):')
for r in out['aa'][:8]:
    print(f"  {r['aa']:15s} {r['nonim']:6d} {r['nim']:6d} {r['diff']:+6d}")
