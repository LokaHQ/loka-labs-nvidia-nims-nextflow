# N=150 benchmark analysis

Every figure in the N=150 report (run `20261103T153827Z`) came out of these
scripts. They are kept so the numbers can be re-derived rather than taken on
trust.

| script | produces |
|---|---|
| `steptime.py` | per-step time and cost from the Nextflow trace |
| `analyse150.py` | per-arm folding confidence, per-chain pLDDT, self-consistency |
| `extra150.py` | cross-arm fold RMSD, amino-acid composition, paired Wilcoxon with BH correction |
| `kabsch.py` | Cα RMSD by Horn quaternion superposition, used by the two above |

No third-party packages: the Wilcoxon signed-rank test and the superposition
are implemented directly because scipy and numpy were not available on the
machine that ran the analysis.

## Inputs

The trace files and score TSVs from both arms, as published to
`s3://nvidia-nims-output/n150-20261103T153827Z/`.

```bash
python3 steptime.py trace_nonim.txt trace_nim.txt
python3 analyse150.py <nonim-dir> <nim-dir>
python3 extra150.py   <nonim-dir> <nim-dir>
```

## One thing to know before reusing them

The two OpenFold3 implementations name their score columns differently, so
`analyse150.py` carries an explicit column map (`avg_plddt`/`ptm`/`iptm`/`gpde`
for the open-source arm, `complex_plddt_score`/`ptm_score`/`iptm_score`/
`complex_pde_score` for the NIM). Matching by position rather than by name is
what makes the two arms comparable.
