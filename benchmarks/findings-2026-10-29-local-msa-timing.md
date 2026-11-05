# Local MSA search: the rebuilt UniRef30 works, and it is slow

2026-10-29. Measured on AWS Batch, `nvidia-nims-cpu-small`, 8 vCPU / 24 GB,
`quay.io/nf-core/proteinfold_colabfold:1.1.1`, databases on FSx Lustre
(`/fsx/colabfold-db`, 2.4 TB, 1,200 MB/s/TiB throughput tier).

## The database reads

`mmseqs tsv2exprofiledb` without `--gpu` produced a database stock MMseqs2 can
open. dbtypes after conversion:

| File | dbtype |
|---|---|
| `uniref30_2302_db` | 2147483648 |
| `uniref30_2302_db_aln` | 2147483653 |
| `uniref30_2302_db_h` | 12 |
| `uniref30_2302_db_seq` | 2147483648 |

`2147483648` is `1<<31`, MMseqs2's compressed flag, which is what an expandable
profile database is expected to carry. The GPU build had `524288` (`1<<19`) and
a `.GPU_READY` marker; neither survives the rebuild.

A single PD-L1 query returned **4,324 sequences**, against 4,370 from the
ColabFold API's UniRef30-only search on the same sequence. The small difference
is the API's own `--diff`/filter settings, not a defective database.

## Wall time

One `colabfold_search` call, one query, start to finish: **68 min 40 s**.

The three MMseqs2 phases report only ~3.5 minutes of processing each, about
10.5 minutes in total. The remaining ~58 minutes is I/O: streaming the 83 GB
`_db_seq` and 43 GB `_db_h` over Lustre. MMseqs2 logs `Can not touch
43200163261 into main memory` - at 24 GB the header database cannot be
preloaded, so every phase pages it in again.

The search arguments only reach the first phase. `colabfold_search` hard-codes
`--db-load-mode 0` for `filterresult` and `result2msa`, so `--db-load-mode 2`
does not apply to the two phases that read `_db_seq`.

## What this costs

`OPENFOLD3_MSA_LOCAL` makes one call per design, with both chains in one FASTA,
so the figure above is the per-design cost.

| Run | MSA tasks | vCPU-hours | Spot | On-demand |
|---|---|---|---|---|
| 5 binders, both arms | 10 | ~104 | ~$1.80 | ~$4.50 |
| 100 binders, both arms | 200 | ~2,080 | ~$35 | ~$90 |

The 4-hour `OPENFOLD3_MSA_LOCAL` timeout holds with room to spare.

## The batching problem at N=100

The 58 minutes is per *call*, not per query: it is the cost of walking the
database once. `colabfold_search` is built to amortise that over many queries in
one invocation.

Running one call per design pays it 100 times for a step that is deliberately
identical on both arms and is meant to contribute nothing to the comparison.
Collecting all designs into a single search would cut the MSA cost of N=100 by
close to two orders of magnitude.

The per-design shape was chosen so each fold starts as soon as its own MSA lands,
matching the NIM arm's streaming behaviour (see the comment in
`workflows/rfd_openfold.nf`). That reasoning holds for the *timed* comparison.
It does not hold for cost, and at N=100 the cost is the binding constraint.

Note also that chain B is the same PD-L1 target in every design, so its
alignment is recomputed identically 100 times.
