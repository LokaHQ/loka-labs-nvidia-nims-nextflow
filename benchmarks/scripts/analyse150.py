#!/usr/bin/env python
import csv, glob, hashlib, json, os, re, statistics as st, sys
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

def idx(p):
    m = re.match(r'design_ppi_[^_]+_(\d+)', Path(p).name)
    return int(m.group(1)) if m else None

def ca(path, chain=None):
    out = []
    for l in Path(path).read_text().splitlines():
        if l.startswith('ATOM') and l[12:16].strip() == 'CA':
            if chain and l[21] != chain:
                continue
            out.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
    return out

def bfac(path, chain):
    return [float(l[60:66]) for l in Path(path).read_text().splitlines()
            if l.startswith('ATOM') and l[12:16].strip() == 'CA' and l[21] == chain]

def seq(path, chain='A'):
    s, seen = '', set()
    for l in Path(path).read_text().splitlines():
        if l.startswith('ATOM') and l[21] == chain:
            rid = l[22:27]
            if rid not in seen:
                seen.add(rid)
                s += AA3.get(l[17:20].strip(), 'X')
    return s

def tsv_rows(d):
    out = {}
    for f in glob.glob(f'{d}/*.tsv'):
        i = idx(f)
        with open(f) as fh:
            r = list(csv.DictReader(fh, delimiter='\t'))
        if r:
            out[i] = r[0]
    return out

def ms(v):
    return (st.mean(v), st.pstdev(v)) if len(v) > 1 else (v[0], 0.0)

res = {}
for arm, base in ARMS.items():
    bb = {idx(f): f for f in glob.glob(f'{base}/rfdiffusion/pdbs/*.pdb')}
    fold = {idx(f): f for f in glob.glob(f'{base}/{OF3[arm]}/pdbs/*.pdb')}
    rel = {idx(f): f for f in glob.glob(f'{base}/{REL[arm]}/*.pdb')}
    sc = tsv_rows(f'{base}/{OF3[arm]}/scores')
    ex = tsv_rows(f'{base}/{OF3[arm]}/extra_scores')
    a = res[arm] = {'bb': bb, 'fold': fold, 'rel': rel, 'sc': sc, 'ex': ex}
    a['bb_sha'] = {i: hashlib.sha256(''.join(f'{x:.3f},{y:.3f},{z:.3f};' for x, y, z in ca(p)).encode()).hexdigest() for i, p in bb.items()}
    a['seq'] = {i: seq(p) for i, p in rel.items()}
    a['len'] = {i: len(ca(p, 'A')) for i, p in bb.items()}
    rm = {}
    for i in sorted(set(bb) & set(fold)):
        x, y = ca(bb[i], 'A'), ca(fold[i], 'A')
        n = min(len(x), len(y))
        if n > 3:
            rm[i] = rmsd(x[:n], y[:n])
    a['rmsd'] = rm

print('=== counts / integrity ===')
for arm in ARMS:
    a = res[arm]
    L = set(a['len'].values())
    print(f'{arm:6s} backbones={len(a["bb"])} folds={len(a["fold"])} scores={len(a["sc"])} bindcraft={len(a["ex"])} binder_len={L}')

shared = sorted(set(res['nonim']['bb_sha']) & set(res['nim']['bb_sha']))
same = sum(res['nonim']['bb_sha'][i] == res['nim']['bb_sha'][i] for i in shared)
print(f'backbone SHA-256 identical: {same}/{len(shared)}')
seq_same = sum(res['nonim']['seq'].get(i) == res['nim']['seq'].get(i) for i in shared)
print(f'ProteinMPNN sequences identical: {seq_same}/{len(shared)}')
ids = []
for i in shared:
    s1, s2 = res['nonim']['seq'].get(i, ''), res['nim']['seq'].get(i, '')
    if s1 and s2 and len(s1) == len(s2):
        ids.append(100.0 * sum(c == d for c, d in zip(s1, s2)) / len(s1))
if ids:
    print(f'mean sequence identity: {st.mean(ids):.1f}%')

print('\n=== OpenFold3 confidence ===')
# The two implementations name the same quantities differently.
COLMAP = {
    'nonim': {'plddt': 'avg_plddt', 'ptm': 'ptm', 'iptm': 'iptm', 'pde': 'gpde'},
    'nim': {'plddt': 'complex_plddt_score', 'ptm': 'ptm_score', 'iptm': 'iptm_score', 'pde': 'complex_pde_score'},
}
for lab in ('plddt', 'ptm', 'iptm', 'pde'):
    line = f'{lab:8s}'
    for arm in ARMS:
        key = COLMAP[arm][lab]
        v = [float(r[key]) for r in res[arm]['sc'].values() if r.get(key)]
        m, s = ms(v)
        line += f'  {arm}={m:8.3f} +/- {s:6.3f}'
    print(line)

print('per-chain pLDDT from PDB B-factors:')
for chain, lab in (('A', 'binder A'), ('B', 'target B')):
    line = f'{lab:10s}'
    for arm in ARMS:
        v = []
        for i, f in res[arm]['fold'].items():
            b = bfac(f, chain)
            if b:
                v.append(st.mean(b))
        m, s = ms(v)
        line += f'  {arm}={m:8.2f} +/- {s:6.2f}'
    print(line)

print('\n=== self-consistency (binder CA RMSD, backbone vs fold) ===')
for arm in ARMS:
    v = sorted(res[arm]['rmsd'].values())
    bad = sum(1 for x in v if x > 10)
    print(f'{arm:6s} n={len(v)} median={st.median(v):.2f} A  mean={st.mean(v):.2f}  >10A: {bad}/{len(v)} ({100*bad/len(v):.0f}%)')

print('\n=== BindCraft ===')
COLS = ['binder_score', 'interface_dG', 'interface_dSASA', 'interface_sc', 'interface_packstat',
        'interface_nres', 'interface_interface_hbonds', 'surface_hydrophobicity', 'i_plddt',
        'ss_plddt', 'unrelaxed_clashes']
for c in COLS:
    line = f'{c:28s}'
    vals = {}
    for arm in ARMS:
        v = [float(r[c]) for r in res[arm]['ex'].values() if r.get(c) not in (None, '')]
        vals[arm] = v
        m, s = ms(v)
        line += f'  {arm}={m:9.2f} +/- {s:7.2f}'
    print(line)

print('\n=== paired test on binder_score ===')
d = []
for i in shared:
    r1, r2 = res['nonim']['ex'].get(i), res['nim']['ex'].get(i)
    if r1 and r2:
        d.append(float(r2['binder_score']) - float(r1['binder_score']))
n = len(d)
mean_d = st.mean(d)
sd_d = st.stdev(d)
se = sd_d / (n ** 0.5)
t = mean_d / se
print(f'n pairs={n}  mean diff (NIM - noNIM)={mean_d:+.2f}  sd={sd_d:.2f}  se={se:.2f}  t={t:+.2f}')
import math
# two-sided p via normal approximation (n=150, df=149)
p = 2 * (1 - 0.5 * (1 + math.erf(abs(t) / math.sqrt(2))))
print(f'two-sided p ~ {p:.4f}')
json.dump({'diff_mean': mean_d, 'sd': sd_d, 't': t, 'p': p, 'n': n}, open(f'{SP}/paired.json', 'w'))
