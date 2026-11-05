#!/usr/bin/env python
import sys, csv, re, statistics as st

RATE = {'nvidia-nims-gpu-standard': 2.240, 'nvidia-nims-cpu-small': 0.384}
UNIT = {'ms': 1 / 1000.0, 's': 1.0, 'm': 60.0, 'h': 3600.0}

def secs(s: str) -> float:
    s = s.strip()
    if not s or s == '-':
        return 0.0
    return sum(float(n) * UNIT[u] for n, u in re.findall(r'([0-9.]+)\s*(ms|h|m|s)', s))

def load(path):
    out = []
    with open(path) as fh:
        for r in csv.DictReader(fh, delimiter='\t'):
            if r['status'] != 'COMPLETED':
                continue
            out.append((r['name'].split(':')[-1].split(' (')[0], secs(r['realtime']), r['queue']))
    return out

for path in sys.argv[1:]:
    print('==', path)
    by = {}
    for n, t, q in load(path):
        by.setdefault(n, []).append((t, q))
    tot_c = tot_t = 0.0
    for n in sorted(by):
        ts = [t for t, _ in by[n]]
        q = by[n][0][1]
        cost = sum(ts) / 3600.0 * RATE.get(q, 0.0)
        tot_c += cost
        tot_t += sum(ts)
        sd = st.pstdev(ts) if len(ts) > 1 else 0.0
        print(f'{n:34s} n={len(ts):4d} mean={st.mean(ts):8.1f}s sd={sd:6.1f} sum={sum(ts)/3600:6.2f}h ${cost:6.2f} [{q}]')
    print(f'{"TOTAL":34s}                           sum={tot_t/3600:6.2f}h ${tot_c:6.2f}  per design ${tot_c/150:.4f}')
