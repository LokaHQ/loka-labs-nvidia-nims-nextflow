# The two pipelines cannot share one copy of the MSA databases

2026-10-29. Branch `benchmark/openfold-vs-nim`.

## Finding

NVIDIA's MSA Search NIM downloads ~1.2 TB of ColabFold databases from NGC and
post-processes them for GPU Server. **Stock MMseqs2 cannot search the result**,
so a self-hosted comparison needs two copies of the same data - roughly 2 TB
rather than 1.2 TB.

This is a real cost of self-hosting the NIM alongside an open-source
equivalent, and it is not mentioned in NVIDIA's documentation, which lists the
individually downloadable databases under their familiar ColabFold names
(`uniref30_2302`, `colabfold_envdb_202108`) without noting that what lands on
disk is not interchangeable with ColabFold's own copy.

## Evidence

`colabfold_search` reads the layout fine: it finds the databases, parses them,
reports `Target database size: 36293491 type: Aminoacid`, and reaches the
prefilter. It then fails, differently depending on whether the NIM's
precomputed index is present.

**With the `.idx`:**

```
Estimated memory consumption: 81G
Process needs more than 27G main memory.
Computed index is too large. Avoid using the index.
Invalid database read for database data file=.../uniref30_2302_db.idx
getData: local id (4294967295) >= db size (19)
Error: Prefilter died
```

**Without it** (memory now fits, 23 GB over 6 splits):

```
Index table: counting k-mers
Index table: Masked residues: 0
No k-mer could be extracted for the database .../uniref30_2302_db.
Maybe the sequences length is less than 14 residues.
Error: Prefilter died
```

**Why**, from reading the database files directly:

| | |
|---|---|
| `uniref30_2302_db` dbtype bytes | `00 00 08 00` = `0x00080000` = `1 << 19` |
| `uniref30_2302_db.GPU_READY` | present |
| `colabfold_envdb_202108_db.GPU_READY` | present |
| First `.index` entries (id, offset, length) | `0 0 4`, `1 4 4`, `2 8 5` |

`1 << 19` is MMseqs2's GPU-extended database flag. The index entries are 4-5
bytes, far short of the 14 residues the prefilter needs for 7-mers, which is
precisely the error it gives. The `.GPU_READY` markers confirm the
post-processing.

## Consequence

The baseline pipeline needs ColabFold's own databases:
`msa_colabfold_db_download.nf`, ~0.8 TB into the 1.1 TB still free on the
filesystem. It deliberately skips `mmseqs createindex` - that index is what
pushed the search to an estimated 81 GB against the 27 GB available, and
without it the same search fits in 23 GB.

Both pipelines still search the same underlying data, from the same ColabFold
release, so the comparison remains valid. They just cannot share the bytes.

## For the write-up

Two quotable points:

1. **Self-hosting both sides costs 2 TB, not 1.2 TB.** The NIM's databases are
   GPU-formatted and not readable by the open-source tool.
2. **The open-source path cannot use the NIM's index at all.** Given identical
   source data, the NIM gets a GPU-accelerated search while `colabfold_search`
   must fall back to reading raw databases - slower, and the reason it runs
   with `--db-load-mode 2`.

## Caveat

Tested with `colabfold_search` from `quay.io/nf-core/proteinfold_colabfold:1.1.1`
(MMseqs2 as bundled there). A newer MMseqs2 with GPU support may well read these
databases; that was not tested, and the claim should be stated as being about
this version rather than about MMseqs2 in general.
