# 3-seed benchmark results

**Status: not yet run.** This file is the shape the results will take; every
table marked *pending* is filled from the run, not written by hand.

PD-L1 binder design, NIM pipeline against baseline, seeds 0 / 5 / 34.

---

## 1. What was run

| | |
|---|---|
| Date | *pending* |
| Seeds | 0, 5, 34 — the same three as the 2026-10-22 comparison |
| Designs | 3, one binder per seed |
| Target | `input/PDL1.pdb`, SHA-256 `d3c95434dcadf26d005340b15bd92be61e101ed921478c26f2a5550f198e61f6` |
| Contigs | `[A18-132/0 55-100]` |
| Hotspots | `A56,A63,A113,A123,A124` |
| Relax cycles | 1 on both sides |
| ProteinMPNN seed | 102 on both sides |
| MSA | **`colabfold_search` on both sides** — see §6 |
| Command | `examples/pdl1-rfd/run-benchmark.sh 3` |

## 2. Container images

Resolved to digests rather than tags, since tags move.

| Stage | NIM pipeline | Baseline pipeline |
|---|---|---|
| RFdiffusion | *pending* | *pending* |
| ProteinMPNN | *pending* | *pending* |
| Thread + relax | *pending* | — |
| MSA | *pending* | *pending* |
| Fold | *pending* | *pending* |
| Scoring | *pending* | *pending* |

## 3. Instances actually used

Not the instance requested — the one Batch chose. Captured in-task from the
instance metadata service, because Batch forgets once a job ends.

| Stage | Pipeline | Instance type | Spot or On-Demand | AZ |
|---|---|---|---|---|
| *pending* | | | | |

## 4. Where the two pipelines diverge

RFdiffusion produces identical backbones at a fixed seed, so any difference in
the final designs must enter at ProteinMPNN or later. This table is the test of
that claim.

| Stage | Measure | Seed 0 | Seed 5 | Seed 34 |
|---|---|---|---|---|
| RFdiffusion | backbone Cα RMSD, NIM vs baseline (Å) | *pending* | *pending* | *pending* |
| ProteinMPNN | binder sequence identity (%) | *pending* | *pending* | *pending* |
| OpenFold3 | refolded complex RMSD (Å) | *pending* | *pending* | *pending* |

## 5. Design quality

`interface_dG` is the primary endpoint: BindCraft runs the same script on both
sides, so its columns are directly comparable. The confidence metrics are
name-normalised across the two pipelines by `bin/benchmark_combine_arms.py`.

| Metric | NIM | Baseline | Note |
|---|---|---|---|
| `interface_dG` | *pending* | *pending* | primary |
| `iptm` | *pending* | *pending* | `iptm` vs `iptm_score` upstream |
| `plddt_complex` | *pending* | *pending* | `avg_plddt` vs `complex_plddt_score` |
| `pae_interaction` | *pending* | **not available** | baseline reports whole-complex only |

Three designs cannot support a statistical claim. Read this as a check that the
pipelines agree, not as evidence of a quality difference either way.

## 6. What this run does NOT measure

**The MSA step.** Both pipelines used `colabfold_search`, so the MSA is
identical on both sides and contributes nothing to the comparison. That is
deliberate: it is better than comparing a GPU-accelerated NIM against a CPU
tool and reporting the difference as a pipeline result.

The reason is not a design choice but an availability one. The MSA Search NIM
needs two 48 GB GPUs, so the smallest instance is a `g6e.12xlarge`. On
2026-10-29 AWS had **no On-Demand capacity for that instance type, or for
`g6e.24xlarge`, in any of the four AZs available to this account** - CloudTrail
records repeated `Server.InsufficientInstanceCapacity` refusals. Spot is not an
option either: one instance is 48 vCPUs against a 32 vCPU account quota for
G-type Spot, so Batch accepts the job and can never place it.

That is a finding in its own right, and belongs in the write-up:

> Self-hosting NVIDIA's MSA Search NIM at the documented specification requires
> hardware that is scarce, cannot use Spot pricing, and was unobtainable for a
> full working day in us-east-1.

See `findings-2026-10-29-msa-databases.md` for the related result that the
NIM's databases are GPU-formatted and unreadable by stock MMseqs2, so the two
implementations cannot share one copy.

## 7. Time and cost

Per process, from the Nextflow trace. Cost is derived from the queue, with the
instance confirmed from §3 where available.

| Stage | Pipeline | Tasks | Median (s) | Total (s) | Est. USD |
|---|---|---|---|---|---|
| *pending* | | | | | |

Caveats that the numbers cannot carry:

- Retries are counted. A design that succeeded on its third attempt costs what
  all three attempts cost.
- Setup dominates at this scale. RFdiffusion alone pays ~21 s of weight
  download and ~53 s of warmup for ~17 s of inference, on both sides.
- These are three designs. Extrapolating to N=100 assumes per-design cost holds,
  which the October run suggests is roughly true but slightly pessimistic, since
  queue and launch time amortises.

## 8. Reproducing

```
aws sso login --profile lokalabs-nims
cd examples/pdl1-rfd && ./run-benchmark.sh 3
```

Analysis:

```
bin/benchmark_combine_arms.py --baseline <dir> --nim <dir> -o combined.tsv
bin/benchmark_sequence_identity.py --baseline <dir> --nim <dir> -o identity.tsv
bin/benchmark_time_cost.py --baseline <trace> --nim <trace> -o cost.tsv
bin/benchmark_provenance.py --queue nvidia-nims-gpu-standard \
    --queue nvidia-nims-cpu-small --since <date> -o provenance.tsv
```
