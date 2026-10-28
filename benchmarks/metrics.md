# Benchmark metrics: what we collect and what we have

NIM vs no-NIM, PD-L1 binder design. Last updated 2026-10-28.

Two pipelines run the same designs from the same seeds and are compared at every
stage, not only at the end. Terminology: the **NIM pipeline** runs each step in
an NVIDIA NIM container; the **baseline pipeline** runs non-NIM equivalents.

---

## 1. What each stage produces, and how the two are compared

| Stage | NIM pipeline | Baseline pipeline | Comparison | Tool |
|---|---|---|---|---|
| Backbone | RFdiffusion NIM | `rfdiffusion-fixed` | Cα RMSD per seed | `bin/rmsd4all.py` |
| Sequence | ProteinMPNN NIM | ProteinMPNN seed-patch | % identity, binder chain | `bin/benchmark_sequence_identity.py` |
| MSA | MSA Search NIM (GPU) | `colabfold_search` (CPU) | alignment depth per chain | counted from the `.a3m` |
| Fold | OpenFold3 NIM | OpenFold3 OSS | confidence metrics | `bin/benchmark_combine_arms.py` |
| Score | BindCraft | BindCraft | `interface_dG` and the rest | `bin/benchmark_combine_arms.py` |
| All | — | — | time and cost per process | `bin/benchmark_time_cost.py` |

Why per stage: RFdiffusion now produces **identical** backbones at a fixed seed,
so any downstream difference must enter at ProteinMPNN or later. That is a sharp,
checkable claim, and it is only checkable if each stage is measured.

## 2. Quality metrics

**Directly comparable — both pipelines emit identical columns.** BindCraft runs
the same script on both sides:

- `interface_dG` — interface binding energy, **the proposed primary endpoint**
- plus the rest of BindCraft's interface columns

**Comparable after normalising names.** The two pipelines report the same
quantities under different names; `benchmark_combine_arms.py` maps them:

| Canonical | Baseline writes | NIM writes |
|---|---|---|
| `plddt_complex` | `avg_plddt` | `complex_plddt_score` |
| `ptm` | `ptm` | `ptm_score` |
| `iptm` | `iptm` | `iptm_score` |
| `pde_complex` | `gpde` | `complex_pde_score` |

**NIM pipeline only — not available on the baseline:**

- `plddt_binder`, `plddt_target` — per-chain confidence
- `pae_interaction` — interface predicted alignment error

`bin/openfold3_predict.py` reports whole-complex confidence only. **If the primary
endpoint becomes `pae_interaction` or `plddt_binder`, the baseline needs that
output added before the run** — per-chain values cannot be recovered from a
whole-complex number afterwards.

## 3. Time and cost

Per process: task count, failed tasks, total and median task seconds, estimated
USD. Extracted from the Nextflow trace, which now carries `cpus`, `memory`,
`queue` and `attempt` — without those, durations cannot become instance-hours.

**Three caveats that the numbers cannot show, and which belong in any write-up:**

1. **Cost is derived from the queue, not the instance.** AWS Batch picks the
   instance and nothing in the pipeline records which. A 2-vCPU job has been
   observed landing on a `g6e.4xlarge`. Use the figures as a ratio between
   pipelines, not as an absolute.
2. **Retries are counted.** A design that succeeded on its third attempt costs
   what all three attempts cost. That is deliberate and is the honest figure.
3. **Setup dominates at small N.** See §4: per-design overhead currently exceeds
   the inference it wraps on both sides.

## 4. What has already been measured

### RFdiffusion — settled

| | |
|---|---|
| Backbone RMSD, NIM vs baseline, seed 0 | **0.00 Å** over 193 residues |
| Output PDB SHA-256 | identical to the reference run — same bytes, not merely the same structure |
| Baseline task | 1 m 37 s |
| NIM task | 1 m 33 s |
| Baseline breakdown | ~21 s weight download, 52.6 s NIM warmup, 16.9 s inference |

The two are within 4 s of each other and produce identical output. **The earlier
"NIM is ~20× faster" was the TensorRT engine build in the old APDI container**,
not the NIM being faster: 1851.5 s on the first call against 9.4 s steady-state.
With engines prebuilt on both sides that difference disappears.

Superseded: the 2026-10-22 measurement of 2.81 / 3.15 / 14.21 Å for seeds
0 / 5 / 34 was taken before `rfdiffusion-fixed` existed.

### MSA — infrastructure ready, not yet measured in-pipeline

| | |
|---|---|
| Databases | 1.2 TB (`uniref30_2302`, `colabfold_envdb_202108`, PDB sets) |
| Download | 89 minutes to FSx for Lustre |
| NVIDIA hosted endpoint, for reference | 5,317-sequence MSA in 2.7 s |

Both pipelines will search these same files. Note the step compares **GPU against
CPU**: the NIM is GPU-accelerated MMseqs2, `colabfold_search` is not. That is a
real capability difference, and should be reported as one rather than folded into
a speed number.

Resource asymmetry worth reporting: the NIM holds cluster consensus sequences in
VRAM (~8 GB UniRef30, ~36 GB envdb); the open-source path wants 128 GB+ of system
RAM for the same search, which is why it runs with `--db-load-mode 2` to mmap off
Lustre instead.

### Historical, for context only

The N=20 run of 2026-10-01 gave $0.156 vs $0.394 per design. **Do not reuse that
figure.** Its stated mechanism was that MSA ran on a cheap CPU queue in the NIM
pipeline; under the current design both pipelines have a separate MSA step and
the NIM's is the GPU one. The number must be re-derived.

## 5. The 3-seed run

| Parameter | Value |
|---|---|
| Seeds | **0, 5, 34** — continuity with the 2026-10-22 comparison |
| Designs | 3, one binder per seed |
| Contigs | `[A18-132/0 55-100]` — a length range, not a fixed 78 |
| Hotspots | `A56,A63,A113,A123,A124` |
| Target | `input/PDL1.pdb` |
| Relax cycles | 1 on both sides |
| ProteinMPNN | seed-patch container, seed 102 to match the NIM |
| MSA | `/fsx/msa`, self-hosted on both sides |

Reproduce with `examples/pdl1-rfd/run-benchmark.sh 3`. A different seed set is
`SEEDS=1,15,30 ./run-benchmark.sh 3`.

**Note on seeds:** the instruction said "0,5,34 for continuity" and also mentioned
"1,15,30". 0,5,34 was taken as the answer since it responded to a direct question;
switching is one environment variable and costs nothing but the run.

## 6. Not yet collected

- **Refold self-consistency** (design backbone vs refolded structure). Promised
  for N=100 in `plan-next-week.md`; neither pipeline computes it. The v1 result
  (1.105 Å vs 3.520 Å) is the single measurement that looked like a real quality
  difference, and the v1 document itself says it needs repeating across many
  backbones. Nearly free during a run, expensive to retrofit.
- **Instance type per task.** Promised to Manuel in the October review replies.
  Until it exists, every cost figure stays "estimated, instance unconfirmed".
- **Statistical test and power.** No committed code. N=100 is justified as
  standard practice; no document states what effect size it can detect. The v1
  primary test at N=20 gave p = 0.164.
- **Whether the RFdiffusion warmup is load-bearing.** Kept because the reference
  parity run used it. One run with `--rfd_nim_warmup_pdb false` would settle it
  and save 53 s per design if not.
