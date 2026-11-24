# Benchmark results as CSV

Long-form exports of the benchmark runs, one observation per row, so the
results can be plotted without re-running any analysis. Produced by
`../scripts/export_csv.py`.

| file | grain | rows |
|---|---|---|
| `tasks.csv` | one pipeline task | time, queue and cost for every task of every run |
| `designs.csv` | one design, one arm | folding confidence, per-chain pLDDT, self-consistency, BindCraft metrics |
| `pairs.csv` | one design, both arms | the matched comparison: backbone identity, sequence identity, cross-arm fold RMSD |
| `versions.csv` | one design, both NIM versions | OpenFold3 NIM 1.5.0 against 1.6.0 on the same inputs: per-chain and complex RMSD, ipTM, pLDDT |
| `batching-model.csv` | one pipeline stage | the stage times and costs the batched whole-pipeline estimate is assembled from |

`run_id` joins them. `arm` is `nonim` (open source) or `nim`.

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

## aws-cost-2026-11-03.csv

Cost Explorer usage records for the N=150 benchmark day, one row per usage
type, at list prices before credits. Usage records only, so credit and refund
lines are excluded.

The two transfer lines are the ones the blog post quotes:

- `NatGateway-Bytes`, 2,265.9 GB, traffic leaving for the internet. Model
  weights account for roughly 1,317 GB of it. The `*-cached` images are the
  same images with the NGC weights baked in, so the ECR size delta is what a
  task downloads: 5.34 GB for OpenFold3, 1.66 GB for RFdiffusion, 0.12 GB for
  ProteinMPNN. The run started 450 NIM servers, plus 150 open-source
  RFdiffusion tasks that ship no weights either, and none shared a cache. The
  remainder covers the verification runs on the same day. This is arithmetic,
  not flow logs: VPC flow logs were never enabled and are not retroactive.
- `DataTransfer-Regional-Bytes`, 3,576.4 GB, cross-AZ traffic. Mostly container
  images, which are 10-18 GB each in this project, pulled onto new instances.
  A weight cache does not reduce this.

Compute lines sum to $67.46 and the two transfer lines to $137.73. The day
total of $212.43 includes verification runs, not only the two benchmark arms,
and transfer is not attributed per arm.

## versions.csv

OpenFold3 NIM 1.5.0 against 1.6.0 on the same 150 inputs, one L40S, identical
harness. The 1.5.0 side is the benchmark's own NIM arm
(`n150-20261103T153827Z/nim`, the PAE-patched 1.5.0 image); the 1.6.0 side is a
replay through the stock 1.6.0 container. Cα RMSD by the Horn quaternion
superposition in `../scripts/kabsch.py`, each chain superposed on itself.

Chain A is the 78-residue binder, chain B the PD-L1 target.

What the post quotes from this file: no prediction identical to 1.5.0's, the
binder chain within 2 Å on 89 of 150, the whole complex on 46 of 150, the
target chain reproducing to a median 0.30 Å, and 13 of the top 20 by ipTM the
same under both versions.

Mean fold time was 12.050 s on 1.5.0 and 3.746 s on 1.6.0 (n=150 each), which
is the 3.2x in the post. Those come from the replay harness, not from this
file.

## batching-model.csv

The whole-pipeline batched figures in the post are assembled, not observed, and
this file is the assembly. RFdiffusion and OpenFold3 carry their measured
`batchval30` times at 15 designs per container; the other four stages keep
their `n150` values, because batching did not change them. Cost per stage is
scaled by the same ratio as the time, at the queue rate that stage already
paid.

It totals 215.0 s and $0.044 per design, which is 37.8% less summed task time
and 65.1% lower modeled compute cost than the open-source arm at one design per
container.

## What these files do not cover

Some numbers in the blog post are not in this directory:

- the elapsed times (about 2 h 30 and about 3 h). The Nextflow trace export
  carries per-task runtimes, not timestamps.
- the 20-binder pilot: the 52.6 s RFdiffusion warmup and the 56.6 to 108.4 s
  step. AWS Batch no longer retains those jobs.
- the batched open-source OpenFold3 baseline, 14.40 s per design.
- the server readiness figures: 97 s for a batched start, 102 to 97 s with
  preloaded weights. The 213 s cold boot and 86 s second container are in
  `s3://nf-binder-workdir/of3-det/summary.txt`.
