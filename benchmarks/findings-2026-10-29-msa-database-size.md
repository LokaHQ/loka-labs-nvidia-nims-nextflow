# Does the small database profile cost us anything?

2026-10-29. Tests whether `databases:uniref30` (~500 GB) would do instead of
`databases:all` (~1.2 TB), which is what we downloaded.

## Measurement

One ColabFold API search for the PD-L1 target (chain A, 115 residues, the
`input/PDL1.pdb` IgV domain). The API returns the UniRef hits and the
environmental hits as separate `.a3m` files, so one search gives both numbers.

| Source | Sequences | Neff (80% identity) |
|---|---|---|
| UniRef30 only | 4,370 | 3,270.0 |
| UniRef30 + ColabFold envdb | 5,317 | 3,496.9 |
| **Environmental contribution** | **+947 (+21.7%)** | **+226.9 (+6.9%)** |

Neff is the redundancy-weighted count: sequences clustered at 80% identity each
contribute a fraction of one. It is the quantity structure prediction actually
responds to, and it says the 947 environmental sequences are mostly
near-duplicates of what UniRef already found.

Normalised, Neff/sqrt(L) is 305 (UniRef only) against 326 (both). Both are far
above the ~100 where AlphaFold-class accuracy saturates, so this target is not
depth-limited either way.

The designed binder gets 2 sequences — itself and nothing else — under both
profiles. A de novo design has no natural homologues, so no database helps it.

Reproduce:

```
bin/colabfold_remote_msa.py --fasta pdl1.fasta -o pdl1_env.a3m
# then count '>' in colabfold_remote_env/uniref.a3m vs the merged output
```

Caveat: the public ColabFold API's databases are the same two NVIDIA ships
(`uniref30_2302`, `colabfold_envdb_202108`) but the versions were not verified
to match byte for byte.

## Conclusion on the science

For this target, dropping the environmental database costs ~7% of effective
depth and nothing at all on the binder side. That is a defensible trade.

## But it does not solve the capacity problem

The small profile was proposed as a way onto hardware that exists. It isn't
one. NVIDIA's GPU requirement is not stated per profile — the supported-GPU
table is unconditional:

| GPU | Memory (GB) | GPU count |
|---|---|---|
| A100 | 80 | 1-8 |
| H100 | 80 | 1-8 |
| L40S | 48 | **2-8** |
| RTX 6000 Ada | 48 | **2-4** |

> Starting with version 2.0.0, GPUs with 48 GB memory (L40S, RTX 6000 Ada)
> require a minimum of 2 GPUs when using GPU Server (enabled by default). This
> is because GPU Server holds databases in memory for optimal performance.

So the 2-GPU floor on L40S holds at any profile size. The small profile saves
disk (and FSx cost), not instance size.

## What would solve it

`NIM_DISABLE_GPU_SERVER=True` runs MMseqs2 on CPU and removes the 2-GPU floor.
Untested here. It makes the NIM runnable on a single 48 GB GPU, but it switches
off the GPU acceleration that is the reason to benchmark the NIM at all, so it
is a way to get the pipeline working, not a way to get a fair timing number.

The other route is a single 80 GB GPU — A100 or H100 is 1-8 GPUs in the table,
so `p4de.24xlarge` or `p5.48xlarge`. Note `p4d.24xlarge` (which was removed
from the `gpu-highmem` queue) carries 40 GB A100s and is below the 48 GB floor;
`p4de` is the 80 GB variant.

## Separate finding worth carrying forward

`NIM_GLOBAL_MAX_MSA_DEPTH` defaults to **500**. Our ColabFold-API MSAs carry
5,317 sequences for this target. Any future NIM-vs-baseline MSA comparison that
does not account for this is comparing a 500-sequence alignment against a
5,317-sequence one, which would swamp any database-coverage effect.
