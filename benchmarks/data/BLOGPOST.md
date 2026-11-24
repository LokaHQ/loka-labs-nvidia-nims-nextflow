# Data behind the blog post

Six files, with what each one is and which heading of the post it sits under.

### [tasks.csv](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/tasks.csv)

Every task with its runtime and cost. Feeds the two tables under **Time:
startup changed the answer** (`run_id` = `n150`) and the speedup table under
**One startup, fifteen designs** (`run_id` = `batchval30`).

### [designs.csv](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/designs.csv)

Per-design scores for both arms. Everything under **Quality: similar
summaries, different designs**: the 3.87 points, the interval, the ipTM pass
counts, the shortlist overlap.

### [pairs.csv](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/pairs.csv)

The matched arm-vs-arm comparison. Behind **ProteinMPNN — sequences** (63%
identity, 2.00 Å) and the 2 Å numbers in the Quality section.

### [versions.csv](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/versions.csv)

OpenFold3 NIM 1.5.0 against 1.6.0 on the same inputs. Behind the version
paragraph at the end of **Quality** and the table under **What a faster model
actually buys**.

### [batching-model.csv](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/batching-model.csv)

How the batched whole-pipeline estimate is put together from the measured
stage times. Behind **What batching changes, and what it does not**, so the
215.0 s and $0.044 can be checked rather than taken on trust.

### [aws-cost-2026-11-03.csv](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/aws-cost-2026-11-03.csv)

Cost Explorer for the benchmark day, one row per usage type. The table under
**Cost: what the compute model leaves out** is this aggregated into four lines.

### [README.md](https://github.com/LokaHQ/loka-labs-nvidia-nims-nextflow/blob/main/benchmarks/data/README.md)

Schemas, which run each file comes from, and a section listing the few numbers
in the post these files do not cover: the elapsed times, the 20-binder pilot,
the batched open-source OpenFold3 baseline, and two server readiness figures.
