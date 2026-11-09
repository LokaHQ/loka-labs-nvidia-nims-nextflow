# Benchmark results as CSV

Long-form exports of the benchmark runs, one observation per row, so the
results can be plotted without re-running any analysis. Produced by
`../scripts/export_csv.py`.

| file | grain | rows |
|---|---|---|
| `tasks.csv` | one pipeline task | time, queue and cost for every task of every run |
| `designs.csv` | one design, one arm | folding confidence, per-chain pLDDT, self-consistency, BindCraft metrics |
| `pairs.csv` | one design, both arms | the matched comparison: backbone identity, sequence identity, cross-arm fold RMSD |

`run_id` joins the three. `arm` is `nonim` (open source) or `nim`.

## Runs

| run_id | arm | what | designs | batch size |
|---|---|---|---|---|
| `n150` | `nonim`, `nim` | the published head-to-head, `n150-20261103T153827Z` | 150 per arm | 1 |
| `batchval30` | `nim` | the batching test, `batchval-20261105T085217Z` | 30 | 15 |
| `n5` | `nonim_plain` | plain upstream RFdiffusion, `benchmark-20261102T224825Z/seeded-plainrfd` | 5 | 1 |
| `n5` | `nonim` | optimised baseline, `benchmark-20261030T182807Z/baseline` | 5 | 1 |
| `n5` | `nim` | NIM arm, `benchmark-20261030T182807Z/nim` | 5 | 1 |

`n5` is the three-way from the 5-binder report. Its arms come from two different
runs, because the plain baseline was only seeded correctly from commit 9012ef7
and had to be re-run on 2 November.

## Regenerating

Raw structures and score files come back from S3 into `raw/`, which is
gitignored - only the CSVs are committed.

```bash
aws s3 sync s3://nvidia-nims-output/n150-20261103T153827Z/nonim/ raw/n150/nonim/ \
  --profile lokalabs-nims --exclude '*/msas/*' --exclude '*/raw/*'
# ...and the same for nim

python3 ../scripts/export_csv.py tasks   --run-id n150 --arm nonim raw/n150/nonim/logs/trace_*.txt -o tasks.csv
python3 ../scripts/export_csv.py tasks   --run-id n150 --arm nim   raw/n150/nim/logs/trace_*.txt   -o tasks.csv --append
python3 ../scripts/export_csv.py designs --run-id n150 --nonim raw/n150/nonim --nim raw/n150/nim -o designs.csv
python3 ../scripts/export_csv.py pairs   --run-id n150 --nonim raw/n150/nonim --nim raw/n150/nim -o pairs.csv
```

## Three things to know before using these

**`n5` does not reproduce the 5-binder report's time and cost tables.** Every
figure in these CSVs is the Nextflow trace's `realtime`, which is what the
N=150 report used and what `steptime.py` computes. The 5-binder report instead
used AWS Batch job durations (`stoppedAt - startedAt`), which include container
start and stop and run about 25% higher: it reports $0.117 / $0.149 / $0.175
per design where the same tasks here give $0.093 / $0.125 / $0.150. The ratio
between the arms is almost unchanged; the absolute numbers are not comparable
across the two reports. Batch no longer retains those jobs, so the report's
figures cannot be regenerated - only the trace-based ones can.

**`realtime_s` is blank, not zero, for a task that never ran.** Aborted and
failed tasks keep their row so the run's history stays visible, but averaging
the column without dropping the blanks understates every mean.

**`batchval30` is reconstructed, not traced.** That run died and resumed five
times, so Nextflow never flushed a trace. Most rows come from the local resume
cache (`nextflow log fervent_torricelli`), which rounds to the second. The four
batched tasks instead carry their exact `realtime` from `.command.trace` in
`s3://nvidia-nims-workdir/work/`, because they are what the 6x claim rests on:

| task | work dir | realtime (ms) |
|---|---|---|
| RFDIFFUSION_NIM (1) | `a5/d82a79b27eccc5ac328a42028a08f2` | 246702 |
| RFDIFFUSION_NIM (2) | `73/45d4b9be42c0315d0191bfc7645907` | 232104 |
| OPENFOLD3_NIM batch 1 | `b2/af5c05fe7971ff2e970be1c0666fbf` | 285596 |
| OPENFOLD3_NIM batch 2 | `54/000dcc52dc7510baa3c781a9ad6550` | 283635 |

The second OpenFold3 batch is absent from the cache entirely - the index file
for the attempt that ran it was lost - and was recovered by scanning the work
bucket. Note that the speed-up is two batches per model, not a distribution.
