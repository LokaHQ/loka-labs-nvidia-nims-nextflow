% PD-L1 Binder Design Benchmark: No-NIMs (OpenFold3) vs. NIM Pipeline
% Run date: 2026-10-01

# 1. Purpose and scope

This document compares the no-NIMs baseline pipeline (`rfd_openfold`) against the
NVIDIA NIM pipeline (`rfd_nim`) on time, cost, and binder quality, using one
matched single-design run of each, executed back to back on 2026-10-01.

**This is n = 1 per pipeline.** It is a clean, correct snapshot of one
comparable run each, not a statistically powered result. No claim that one
pipeline is "faster" or "better" should be drawn from this data alone. A
follow-up run of N ~ 20-30 designs per pipeline, compared with a non-parametric
significance test (Mann-Whitney U) on a locked primary metric, is the next
step before any such claim is made (e.g., for the team blog post).

Section 8 adds a separate side-investigation into whether packaging a model
as a NIM changes its numeric precision versus the open-source baseline, and
whether that has a measurable effect on output — static config checks,
empirical same-input diffs, a measured noise floor for context, and an
RFdiffusion seed-sync attempt (which produced a real, useful negative
result). That section is its own set of single-input checks, separate from
the n=1 pipeline benchmark above.

Git: both pipelines were run from a single branch,
`feature/aws-batch-nims-smoke-test` @ `c61e542` (merge of the baseline
OpenFold3 work into the NIM branch), checked out locally as
`benchmark/openfold-vs-nim`.

# 2. What we did to make the pipelines comparable

Before this run, the following were checked and/or fixed so the comparison
would be fair:

- **Locked identical inputs** across both runs: same target PDB, contigs,
  hotspot residue, `rfd_n_designs=1`, `pmpnn_seqs_per_struct=1`.
- **Confirmed MSA search is already equivalent**: both pipelines query the
  same ColabFold host (`https://api.colabfold.com`) in the same mode (`env`
  + filter, independent/unpaired per-chain search), with the same chain
  convention (A = binder, B = target). Verified by direct inspection of both
  code paths, not assumed.
- **Fixed a queue-routing asymmetry**: the baseline profile had CPU-only
  steps (BindCraft scoring, combine-scores, unique-id) running on the
  expensive GPU queue by inheritance. This was fixed (independently, by both
  of us) to route them to the cheap CPU-small queue, matching the NIM
  profile's existing pattern.
- **Established BindCraft's own TSV as the primary quality metric.** Both
  pipelines call the identical BindCraft container/script against the
  OpenFold3 output PDB, computing interface metrics directly from coordinates
  and B-factors. This is the one part of the comparison that was already
  apples-to-apples, regardless of which OpenFold3 variant produced the
  structure.
- **Flagged, not hidden, one remaining asymmetry**: the two pipelines' own
  native OpenFold3 scores differ in shape (baseline: whole-complex-blended
  `avg_plddt/ptm/iptm/gpde`; NIM: chain-split `plddt_binder/plddt_target` +
  Angstrom `pae_interaction` via a custom response patch). These are reported
  below as secondary/diagnostic, not used for the primary comparison.
- **Execution discipline**: both pipelines were run strictly sequentially
  (baseline to completion, then NIM), not concurrently, so they would not
  compete for the same GPU Spot capacity and skew each other's queue-wait
  time. Neither run used `-resume`, so no step's timing is artificially
  near-zero from a cached result.
- **Noted where MSA time is counted differently**: the baseline's single
  `OPENFOLD3` process runs its own MSA search internally; the NIM pipeline
  runs MSA search as a separate `OPENFOLD3_MSA` process before
  `OPENFOLD3_NIM`. Section 4 reports both the per-process view and a summed
  "OpenFold3-equivalent step" view (baseline `OPENFOLD3` vs. NIM
  `OPENFOLD3_MSA + OPENFOLD3_NIM`) so this doesn't quietly bias the time
  comparison either way.

# 3. Locked inputs

| Parameter | Baseline (`rfd_openfold`) | NIM (`rfd_nim`) |
|---|---|---|
| Target PDB | `examples/pdl1-rfd/input/PDL1.pdb` (identical file) | identical |
| Contigs | `[A18-132/0 78-78]` | identical |
| Hotspot residue | `A56` | identical |
| `rfd_n_designs` | 1 | 1 |
| `pmpnn_seqs_per_struct` | 1 | 1 |
| Sample count | `pmpnn_relax_cycles=1` | `of3_diffusion_samples=1` |
| Profile | `aws_batch_openfold` | `aws_batch_nims` |
| `-resume` used? | No | No |
| Run order | 1st (11:08:59 - 11:59:25 UTC) | 2nd (11:59:33 - 12:57:27 UTC), started only after baseline fully completed |

# 4. Time

## 4.1 Per-process breakdown

All times from `aws batch describe-jobs`, split into **queue+launch**
(`startedAt - createdAt`: Batch scheduling, Spot/EC2 launch, container image
pull) and **compute** (`stoppedAt - startedAt`: actual task execution).

### Baseline (`rfd_openfold`) — 5 jobs, 0 failures

| Process | Queue | Queue+launch | Compute | Total |
|---|---|---|---|---|
| UNIQUE_ID | cpu-small | 198.5s | 10.2s | 208.7s |
| RFDIFFUSION | gpu-standard | 398.7s | 56.6s | 455.3s |
| DL_BINDER_DESIGN_PROTEINMPNN | cpu-small | 363.8s | 90.9s | 454.7s |
| OPENFOLD3 | gpu-standard | 417.7s | 159.7s | 577.4s |
| BINDCRAFT_SCORING_AF2IG | cpu-small | 537.8s | 87.8s | 625.6s |
| **Total (sum of jobs)** | | **1916.5s** | **405.2s** | **2321.7s (38m 42s)** |

### NIM (`rfd_nim`) — 7 jobs, 0 failures

| Process | Queue | Queue+launch | Compute | Total |
|---|---|---|---|---|
| UNIQUE_ID | cpu-small | 234.6s | 10.8s | 245.4s |
| RFDIFFUSION_NIM | gpu-standard | 373.0s | 107.7s | 480.7s |
| DL_BINDER_DESIGN_PROTEINMPNN_NIM | gpu-standard | 12.4s* | 20.3s | 32.7s |
| THREAD_AND_RELAX | cpu-small | 376.6s | 75.0s | 451.6s |
| OPENFOLD3_MSA | cpu-small | 58.3s* | 54.1s | 112.4s |
| OPENFOLD3_NIM | gpu-standard | 273.9s | 125.0s | 398.9s |
| BINDCRAFT_SCORING_OPENFOLD3 | cpu-small | 505.2s | 81.6s | 586.8s |
| **Total (sum of jobs)** | | **1834.0s** | **474.5s** | **2308.4s (38m 28s)** |

\* These two steps reused an already-warm instance left running by the
previous step (same container instance ID — see Section 5), so queue+launch
time is much lower than a cold start.

## 4.2 Total wall-clock vs. total Batch-job time

| | Total AWS Batch-job time (sum of jobs) | End-to-end wall-clock | Difference (Nextflow-side overhead: local scheduling, S3 staging, polling, report generation) |
|---|---|---|---|
| Baseline | 38m 42s | **50m 26s** | 11m 44s |
| NIM | 38m 28s | **57m 54s** | 19m 26s |

**Finding**: the two pipelines' actual AWS Batch compute+queue time is nearly
identical (38m42s vs 38m28s). The ~7.5-minute wall-clock gap is Nextflow
orchestration overhead, which scales with process count (NIM has 7 processes
vs. baseline's 5) — not a difference in the underlying NIM vs. non-NIM
infrastructure.

## 4.3 OpenFold3-equivalent step (apples-to-apples sub-comparison)

| | Queue+launch | Compute | Total |
|---|---|---|---|
| Baseline `OPENFOLD3` (includes its own MSA search) | 417.7s | 159.7s | **577.4s** |
| NIM `OPENFOLD3_MSA` + `OPENFOLD3_NIM` (summed) | 332.2s | 179.1s | **511.3s** |

In this single run, the NIM path's OpenFold3-equivalent step was ~11% faster
in total time than baseline's, driven by `OPENFOLD3_MSA` reusing an
already-warm CPU instance (near-zero queue wait) while compute time was
similar on both sides. This reverses the "NIM is slower" impression from an
earlier isolated test — one more reason this needs the N-design follow-up
before anyone draws a general conclusion.

# 5. Which instance ran each step

Resolved via `aws batch describe-jobs` -> `container.containerInstanceArn` ->
`aws ecs describe-container-instances` -> EC2 instance ID/type/AZ.

### NIM — fully resolved (captured promptly after the run)

| Process | Instance ID | Type | AZ | Lifecycle |
|---|---|---|---|---|
| UNIQUE_ID | i-077eb7e2ef9da8ef4 | c5.large | us-east-1c | Spot |
| RFDIFFUSION_NIM | i-0edd93afdaa7e5897 | g6e.4xlarge | us-east-1b | Spot |
| DL_BINDER_DESIGN_PROTEINMPNN_NIM | i-0edd93afdaa7e5897 (same as above) | g6e.4xlarge | us-east-1b | Spot |
| THREAD_AND_RELAX | i-062dee29a73d8bc6b | c5.xlarge | us-east-1a | Spot |
| OPENFOLD3_MSA | i-062dee29a73d8bc6b (same as above) | c5.xlarge | us-east-1a | Spot |
| OPENFOLD3_NIM | i-0e7d5892b575aa6ae | g6e.4xlarge | us-east-1c | Spot |
| BINDCRAFT_SCORING_OPENFOLD3 | i-02bd2cc768ffbab84 | m5.large | us-east-1b | Spot |

### Baseline — **not resolved**

By the time instance resolution was attempted (after both runs completed,
~1.5-2 hours after baseline's jobs ran), baseline's container-instance
records had already been purged from ECS, and the underlying EC2 instances
had aged out of `describe-instances`' visibility window. A CloudTrail lookup
for the launch events returned mostly Batch's own Spot-capacity dry-run
probes rather than the real launch, and wasn't pursued further for this n=1
snapshot.

**Lesson for the N-design follow-up run**: resolve instance IDs immediately
after each run completes, not after both runs are done.

What we do know from the resource requests and each queue's allowed instance
types: `RFDIFFUSION` (2 vCPU/16GB/1 GPU) fits `g6e.2xlarge`; `OPENFOLD3`
(8 vCPU/64GB/1 GPU) does not fit `g6e.2xlarge`'s schedulable memory and would
have required at least `g6e.4xlarge` (consistent with what NIM's
similarly-sized `OPENFOLD3_NIM` job actually got). The three CPU-only jobs
would have landed on `nvidia-nims-cpu-small`'s instance types (`m5`/`c5`
family).

**Observed in this benchmark**: Batch's Spot allocation does not always pick
the smallest-fitting instance size — e.g. NIM's `RFDIFFUSION_NIM` (same
2 vCPU/16GB/1 GPU request) landed on `g6e.4xlarge`, not the smaller
`g6e.2xlarge` it would fit on. This appears to be Spot capacity/price-driven
instance selection, not a configuration issue.

# 6. Cost (AWS Batch compute only)

Methodology: `(queue+launch + compute) x real Spot price for the resolved AZ
and instance type`. Excludes S3/ECR/data transfer (shown in an earlier
spend estimate to be a few dollars total across the whole project to date).

### NIM — confirmed (real instances, real AZ-matched Spot prices)

| Process | Instance | Spot $/hr | Cost |
|---|---|---|---|
| UNIQUE_ID | c5.large | $0.0273 | $0.0019 |
| RFDIFFUSION_NIM | g6e.4xlarge | $2.1633 | $0.2888 |
| DL_BINDER_DESIGN_PROTEINMPNN_NIM | g6e.4xlarge (shared instance) | $2.1633 | $0.0196 |
| THREAD_AND_RELAX | c5.xlarge | $0.0592 | $0.0074 |
| OPENFOLD3_MSA | c5.xlarge (shared instance) | $0.0592 | $0.0018 |
| OPENFOLD3_NIM | g6e.4xlarge | $2.2805 | $0.2527 |
| BINDCRAFT_SCORING_OPENFOLD3 | m5.large | $0.0459 | $0.0075 |
| **Total** | | | **$0.5797** |

### Baseline — estimated (instance type unconfirmed, see Section 5)

Using the smallest-fitting instance per the resource request (consistent with
the methodology used in the earlier aggregate AWS spend estimate this
session), with Spot prices from the same day:

| Process | Assumed instance | Spot $/hr | Cost (est.) |
|---|---|---|---|
| UNIQUE_ID | c5.large/m5.large | ~$0.027-0.046 | ~$0.002 |
| RFDIFFUSION | g6e.2xlarge | ~$2.21 | ~$0.280 |
| DL_BINDER_DESIGN_PROTEINMPNN | c5.large/m5.large | ~$0.027-0.046 | ~$0.005 |
| OPENFOLD3 | g6e.4xlarge | ~$2.28-2.70 | ~$0.366-0.433 |
| BINDCRAFT_SCORING_AF2IG | c5.large/m5.large | ~$0.027-0.046 | ~$0.006 |
| **Total (est.)** | | | **~$0.65-0.73** |

**Finding**: on the OpenFold3-equivalent step specifically (Section 4.3), NIM
came out cheaper (~$0.2545 = $0.0018 MSA + $0.2527 inference) than baseline's
single combined step (~$0.37-0.43 estimated), because baseline pays
GPU-instance pricing for its internal MSA search time, while NIM's
architecture runs that same MSA search on the cheap CPU queue and only pays
GPU pricing for the actual model inference call.

# 7. Binder quality

## 7.1 Primary metric: BindCraft scoring (identical scorer, both sides)

| Metric | Baseline | NIM |
|---|---|---|
| binder_score | -193.53 | -205.53 |
| interface_dG | -48.09 | -40.83 |
| interface_dSASA | 1485.9 | 1539.97 |
| interface_sc (shape complementarity) | 0.61 | 0.66 |
| interface_packstat | 0.72 | 0.66 |
| interface_nres | 16 | 15 |
| interface_hbonds | 10 (62.5%) | 5 (33.3%) |
| interface_delta_unsat_hbonds | 0.0 | 3.0 (20.0%) |
| i_plddt | 0.89 | 0.89 |
| ss_plddt | 0.92 | 0.93 |
| unrelaxed/relaxed clashes | 0/0 | 0/0 |

Both designs score reasonably and comparably on most metrics; baseline has
more interface hydrogen bonds and fewer unsatisfied H-bonds, NIM has
marginally better shape complementarity. **n=1 — not a basis for a quality
verdict either way.**

## 7.2 Secondary/diagnostic: each pipeline's own native OpenFold3 scores

**Not directly comparable between pipelines** (different chain-scoping,
different scales) — included for completeness only.

| Baseline (`avg_plddt/ptm/iptm/gpde`) | NIM (`plddt_binder/plddt_target/pae_interaction` + raw) |
|---|---|
| avg_plddt: 89.91 | plddt_binder: 87.01 |
| ptm: 0.858 | plddt_target: 91.45 |
| iptm: 0.729 | pae_interaction: 7.63 Angstrom |
| gpde: 0.407 | confidence_score: 0.780 |
| | complex_plddt_score: 89.22 |
| | complex_pde_score: 0.461 |
| | ptm_score: 0.806 |
| | iptm_score: 0.690 |

## 7.3 Binder sequences generated (for reference — expected to differ)

RFdiffusion/ProteinMPNN seeds are not synchronized between the two
implementations, so these are two independently generated designs, not the
same design scored two ways. This is expected and correct for this
comparison type, not an error:

- Baseline: `APLAVAAAAAAEARAAAAELAALGGAEEAAALTAEAEAALAAAEAATDPAVKAAEADKVRAARGRAEALVARALAKKE`
- NIM: `KEEEEKKEKEKKEKEKEKEKLKKEEELKELMEAAERRALEAAAERLRAEAERLEAEGRLEEAAEKRREAEALEAELAA`

# 8. Numeric precision: OSS vs. NIM

Separate from the pipeline-level benchmark above: does packaging a model as a
NIM change its numeric precision, and if so, does that measurably change the
output? Checked two ways — a static check of each container's actual
configuration, and an empirical check using matched input.

## 8.1 Static check (each container's declared precision, inspected directly)

Checked via each NIM's own NVIDIA model manifest
(`/opt/nim/etc/default/model_manifest.yaml`) and each OSS container's source
code — not assumed.

| Model | NIM | OSS baseline |
|---|---|---|
| RFdiffusion | **`precision: fp16`**, TensorRT-compiled (`profile: trt`), confirmed across every supported GPU (A100, A10G, L40S, H100, GB200, etc.) | Explicitly *disables* autocast (`@torch.cuda.amp.autocast(enabled=False)`) on at least one numerically-sensitive module; no broad reduced-precision policy found — runs essentially FP32 |
| ProteinMPNN | No TensorRT profile at all (`tags: {}`); loads the same raw PyTorch `.pt` checkpoints as OSS | Standard PyTorch, no precision override found |
| OpenFold3 | **`precision: fp16`**, TensorRT-compiled, confirmed across an extensive GPU list (A100 variants, B200/B300, GB200/GB300, H100/H200, L40S, RTX 6000 Ada/Pro, etc.) | Not pure FP32 either — its attention and normalization code forces conversion to `bfloat16` internally by default |

**Finding**: RFdiffusion has a clean, confirmed precision gap (NIM fp16 vs.
OSS ~fp32). ProteinMPNN has no gap — identical precision both sides. OpenFold3
is the ambiguous one: both sides already use some form of reduced precision,
just via different mechanisms (OSS: selective bf16 in specific layers; NIM:
full fp16 TensorRT compilation) — which is why the empirical check below
matters most for this model specifically.

## 8.2 Empirical check: OpenFold3 OSS vs. NIM on identical input

**Method**: RFdiffusion and ProteinMPNN are both stochastic and weren't
seed-synced between the two pipeline runs (Section 7.3), so their outputs
differ — that rules out directly diffing Section 7's two OpenFold3 outputs
for a precision signal; the difference would be confounded with
"these are two different proteins." Instead: took the baseline run's
**already-generated** threaded complex PDB
(`design_ppi_3ERYdgB_0_dldesign_0_cycle1_mpnn0.pdb` — the exact binder+target
sequence baseline's own OpenFold3 folded) and fed that **same file** directly
into the NIM's `OPENFOLD3_MSA` + `OPENFOLD3_NIM` steps, bypassing RFdiffusion/
ProteinMPNN entirely. Both OpenFold3 implementations therefore processed the
identical input sequence.

### Native scores, same input, both implementations

| Metric | OSS (baseline) | NIM |
|---|---|---|
| Complex-level pLDDT | avg_plddt: 89.91 | complex_plddt_score: 88.37 |
| ptm | 0.858 | 0.824 |
| iptm | 0.7288 | 0.7288 |
| pde/gpde | 0.407 | 0.527 |

`iptm` matched to four decimal places (0.72881 vs. 0.72885) — striking
agreement given the precision difference. `ptm` and `pde` diverge more
(~4% and ~30% relative, respectively).

### Structural comparison (CA-atom RMSD, Kabsch-superposed)

| | RMSD | Residues |
|---|---|---|
| Whole complex (one global superposition) | 1.203 A | 193 |
| Chain A (binder), superposed on itself | **0.488 A** | 78 |
| Chain B (target), superposed on itself | **0.469 A** | 115 |

The whole-complex RMSD is higher than either per-chain RMSD because it also
captures the relative docking angle between the two chains (a separate,
known source of prediction variability, not a precision artifact). Each
chain's own fold, taken independently, matches to well under half an
angstrom between the FP16 NIM and the OSS baseline.

### Per-residue pLDDT (B-factor column, both implementations write it the same way)

| | OSS mean | NIM mean | Mean abs. difference |
|---|---|---|---|
| Whole complex | 93.13 | 91.94 | 1.64 (max 7.91) |
| Chain A (binder) | 90.81 | 90.93 | 0.99 |
| Chain B (target) | 94.71 | 92.63 | 2.09 |

**Finding**: despite a confirmed precision difference (NIM's fp16 TensorRT
compilation vs. OSS's mixed-precision PyTorch), OpenFold3's actual predicted
structure for this input is nearly identical between the two implementations
— sub-angstrom per-chain RMSD, pLDDT within ~1-2 points. The larger
differences show up in the derived confidence scores (`ptm`, `pde`) more than
in the structure itself. For this one input, NIM's speed/cost optimization
via reduced precision does not appear to come at a meaningful structural
accuracy cost — though this is still a single data point, not a systematic
study. **Confirmed against a real noise floor in 8.3 below**: the
cross-implementation gap (~0.47-0.49 A per chain) is roughly 10-40x larger
than either implementation's own run-to-run variance, so this is a real
signal, not measurement noise.

## 8.3 Follow-up checks

Two gaps identified after 8.1/8.2. Both were run; one needed a second attempt
after an implementation bug was caught before being written up as a finding
(see below) — flagging that explicitly rather than silently fixing it,
since it's relevant to how much to trust ad-hoc single-run checks like these.

### Noise floor (completed)

Section 8.2's RMSD/score differences had no reference point on their own —
without knowing how much each implementation varies run-to-run absent any
precision difference, there was no way to tell if the cross-implementation
gap was real or just noise. `noise_floor_check.nf` re-ran both OSS OpenFold3
and NIM OpenFold3 a second, independent time on the exact same input used in
8.2.

| | Whole-complex RMSD | Chain A (binder) | Chain B (target) | pLDDT mean abs. diff |
|---|---|---|---|---|
| OSS, run 1 vs. run 2 | 0.011 A | 0.011 A | 0.009 A | 0.04 |
| NIM, run 1 vs. run 2 | 0.054 A | 0.028 A | 0.051 A | 0.25 |

Both implementations are highly self-consistent (OSS more so than NIM, but
both well under 0.1 A). Compared against Section 8.2's cross-implementation
per-chain RMSD of 0.47-0.49 A, this confirms that gap is a genuine
OSS-vs-NIM difference — roughly 10x NIM's own noise floor and ~40x OSS's —
not an artifact of either implementation's inherent run-to-run variance.
Native scores also reproduced tightly on both sides (e.g. OSS `avg_plddt`:
89.91 vs. 89.87; NIM `iptm`: 0.7288 vs. 0.7173).

**Is NIM's larger noise floor fixable?** Checked whether OpenFold3-NIM's API
exposes a seed field the way RFdiffusion-NIM's does (Section 8.3 below) —
it doesn't; no `seed` field anywhere in its request schema. There's no
documented lever to tighten NIM's self-consistency via the public API. This
isn't a problem needing a fix, though: 0.054 A is already small enough that
it didn't obscure the real cross-implementation signal above — a tighter
noise floor would be a nice-to-have, not a blocker.

### RFdiffusion seed-sync (completed, after fixing a real bug in the check itself)

Section 8.1 found a confirmed, real precision gap for RFdiffusion (NIM: fp16
TensorRT; OSS: ~fp32) but — unlike OpenFold3 — no empirical structural test,
since RFdiffusion's stochastic sampling means the two pipeline runs in this
document never shared an input at that stage. OSS exposes
`inference.deterministic` (seeds by design index, verified in
`run_inference.py`); the NIM's `/generate` endpoint exposes a documented
`random_seed` field (confirmed in `/opt/nim/model_defs.py`) that NIM's call
script didn't previously send. Added `random_seed` support to
`bin/rfdiffusion_nim_call.py` and threaded it through `RFDIFFUSION_NIM`/
`rfd_nim.nf` as a new optional, backward-compatible parameter
(`params.rfd_random_seed`, default `false`).

**First attempt was invalid, caught before being reported as a finding.**
The module exported the seed with `${random_seed ? ... : ''}`. In Groovy,
`0` is falsy — so passing `random_seed=0` silently skipped exporting
`RFD_RANDOM_SEED` entirely. The result was effectively "OSS seeded at 0" vs.
"NIM running completely unseeded," which produced a 19.4 A whole-complex
RMSD — structurally unrelated backbones. That number was verified against
the actual `.command.sh` sent to the container before being written up, which
is how the bug was caught: the env var was simply absent. Fixed to
`${random_seed != false ? ... : ''}` (treating `false`, not falsiness, as
"unset") and re-run.

**Corrected result**: confirmed `RFD_RANDOM_SEED="0"` was actually present in
the re-run's `.command.sh` this time before trusting the numbers below.

| | RMSD |
|---|---|
| Whole complex | 15.678 A |
| Chain A (binder — the part RFdiffusion actually generates) | **18.660 A** |
| Chain B (target — fixed/conditioning input, not generated) | 0.026 A |

**Finding: matching the seed value does not produce matching output.**
Chain B's near-perfect agreement isn't evidence the seed worked — that chain
is the fixed target region RFdiffusion copies through from the input
unchanged regardless of any seed, on both implementations. Chain A, the
actual *generated* binder, is as different as two unrelated random designs
(18.66 A — compare to the noise-floor-confirmed sub-angstrom agreement
OpenFold3 showed in 8.2/8.3 for the same kind of cross-implementation check).
**Root cause, confirmed by reading both implementations' actual source, not
guessed:** NIM's `model_utils.py` constructs its sampler as
`model_runners.SelfConditioning(conf, rngs=RNGs(random_seed))`, where `RNGs`
is a dedicated class imported from `rfdiffusion.rng` — a seed object
explicitly injected into the sampler. **That class, and that constructor
signature, do not exist in our pinned OSS container at all.** OSS's
`SelfConditioning.__init__(self, conf)` takes only `conf` — no `rngs`
parameter, no `rfdiffusion/rng.py` module anywhere in the OSS package. NIM is
built from a newer or modified RFdiffusion codebase that added dedicated,
explicitly-injectable seeded-sampling infrastructure which was never
backported to the OSS release this repo pins. OSS's own
`inference.deterministic` flag is a different, older mechanism — it seeds
Python's global RNG state (`torch.manual_seed`/`np.random.seed`/`random.seed`)
consumed by whatever the sampling loop happens to call, in whatever order OSS's
code calls it. Both implementations accepted the value `0` without error, but
there was never a reason to expect they'd draw the same noise sequence from
it, since they aren't even using the same seeding mechanism internally — and
empirically, confirmed above, they don't.

**Is this fixable?** Only with real source-patching effort, and even then not
guaranteed. A genuine fix would mean adding the missing `rng.py` module to
the OSS container and rewiring `SelfConditioning` to accept and use it the
way NIM's wrapper does — a real change to third-party code, not a config
flag, with no guarantee the TensorRT-compiled engine would consume that
injected state identically to the PyTorch eager-mode sampler even if the
plumbing were made to match (the precision/compilation difference itself
could still make the trajectories diverge). Given the main N-design
statistical benchmark (Section 9) doesn't require this — it compares
independently-generated designs, which is the statistically correct method
regardless — this is a real but low-value fix. Recommended: don't invest in
it unless a specific future need calls for a paired RFdiffusion comparison
specifically.

This means RFdiffusion's confirmed fp16-vs-fp32 precision gap (8.1) remains
structurally untested by a paired method; a same-noise comparison isn't
achievable just by passing matching integers to each API. The already-planned
unpaired N-design statistical benchmark is the correct way to assess
RFdiffusion-driven differences between the two pipelines — this result
confirms that's a necessity for RFdiffusion, not just a convenient choice.

# 9. Interpretation

What this run supports:
- Both pipelines are functionally correct end to end (0 failures, both arms).
- Actual AWS Batch compute+queue time is nearly identical between the two
  pipelines; wall-clock differences so far trace to Nextflow orchestration
  overhead (process count), not to NIM vs. non-NIM infrastructure being
  inherently faster or slower.
- Binder quality (via the shared BindCraft scorer) looks broadly comparable
  in this one design.
- NIM's split MSA/inference architecture may be more cost-efficient per
  OpenFold3 call, since it avoids paying GPU-instance pricing for MSA search
  time.
- RFdiffusion-NIM and OpenFold3-NIM both run at confirmed fp16 precision
  versus the OSS baseline's closer-to-fp32 execution, but for the one
  OpenFold3 input tested, this did not translate into a meaningfully
  different predicted structure — confirmed against a measured noise floor
  (8.3), not just a single uncontrolled comparison.
- Ad-hoc single-run checks like these need their own verification discipline:
  the first RFdiffusion seed-sync attempt produced a dramatic, wrong result
  (19.4 A RMSD) caused by a Groovy falsy-zero bug, not a real finding — caught
  by checking the actual command sent to the container before writing it up.
  Worth remembering before trusting any one-off script's output at face value.
- Matching the integer seed value does **not** make OSS and NIM RFdiffusion
  generate the same binder, even once the bug above was fixed and the seed
  was confirmed delivered: the actual generated chain differed by 18.66 A,
  essentially unrelated designs (the 0.026 A agreement on the other chain is
  just the fixed target region passing through unchanged, not a sign the
  seed worked). The two implementations' RNGs are not interchangeable via a
  shared seed label.

What this run does **not** support:
- Any statistically defensible claim that one pipeline produces better/worse
  binders, or is reliably faster/cheaper. That requires the planned N ~ 20-30
  replicate-design follow-up, scored on a single locked primary metric
  (recommended: BindCraft's `binder_score` or `interface_dG`), compared with
  Mann-Whitney U.
- A systematic claim about precision/quality tradeoffs from a single paired
  comparison — both Section 8 checks are one input each. OpenFold3's result
  is backed by a measured noise floor and shows a real but small
  implementation gap; RFdiffusion's confirmed fp16-vs-fp32 gap (8.1) remains
  structurally untested, since seed-matching turned out not to be a viable
  way to get a paired comparison for this model. Any claim about
  RFdiffusion's precision impact needs the unpaired N-design statistical
  approach instead, not a paired diff.

# 10. Appendix

- Baseline output: `s3://nvidia-nims-output/benchmarks/pdl1-run-20261001T110859Z/baseline/`
- NIM output: `s3://nvidia-nims-output/benchmarks/pdl1-run-20261001T110859Z/nim/`
- Both include `params.json` and Nextflow `report`/`timeline`/`dag` HTML files
  under `logs/`.
- Job IDs (baseline, in order): `4e662c18-4f68-4afb-a143-e35fd59fcd91`,
  `1f77c669-cbb5-46a0-b976-5a9484a46ff8`, `29532f60-bd32-4cb7-9db0-f1f381c928da`,
  `16a459e2-70fd-407a-8f4d-664c8a27f691`, `1b129ece-f29a-4571-a624-e92b5b182577`
- Job IDs (NIM, in order): `be0b20ef-9b8c-4fdf-ae00-d17c64e26b80`,
  `9ec029d6-8775-4314-add6-1435f332e078`, `0b215e58-996a-4057-a5ec-14596fc8f326`,
  `6ef53487-13fd-47df-a2aa-339e8742f3b0`, `61ee6e52-7436-43d3-9902-929ea187c547`,
  `b4c6c76b-bd21-4fcb-8938-055e67fc27bc`, `55bf15a3-c426-4db4-b2b1-01daebbb71e2`
- Git: `feature/aws-batch-nims-smoke-test` @ `c61e542`
- Precision-check output: `s3://nvidia-nims-output/benchmarks/pdl1-run-20261001T110859Z/precision-check/`
  (ad-hoc, single-purpose `precision_check.nf` at the repo root — not part of
  the pipeline, feeds one existing PDB into `OPENFOLD3_MSA` + `OPENFOLD3_NIM`
  directly, bypassing RFdiffusion/ProteinMPNN)
- Noise-floor output: `s3://nvidia-nims-output/benchmarks/pdl1-run-20261001T110859Z/noise-floor/`
  (ad-hoc `noise_floor_check.nf`)
- Seed-check output (first, invalid attempt — kept for the record, not for
  conclusions): `s3://nvidia-nims-output/benchmarks/pdl1-run-20261001T110859Z/seed-check/`
- Seed-check output (corrected): `s3://nvidia-nims-output/benchmarks/pdl1-run-20261001T110859Z/seed-check-v2/`
  (ad-hoc `seed_check.nf`)
- Code changes made for the seed-sync check, all small and backward-compatible:
  `bin/rfdiffusion_nim_call.py` (added optional `RFD_RANDOM_SEED` env var ->
  `random_seed` in the request payload), `modules/local/rfd/rfdiffusion_nim.nf`
  (new `random_seed` process input), `workflows/rfd_nim.nf` (new
  `params.rfd_random_seed = false` default, threaded through to
  `RFDIFFUSION_NIM`). Not yet committed/pushed.
- Ad-hoc config: `ad_hoc_mixed.config` at the repo root supplies resource
  configs for OSS process names (`RFDIFFUSION`, `OPENFOLD3`) when running
  mixed OSS+NIM ad-hoc workflows under the `aws_batch_nims` profile, which
  otherwise only defines the NIM-named processes.
