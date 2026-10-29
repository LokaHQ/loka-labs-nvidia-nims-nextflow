# Pre-flight checklist: 3-seed run, then N=100

2026-10-22, revised 2026-10-28. Branch `benchmark/openfold-vs-nim`.

**Order (set 2026-10-28):**

1. Wire Manuel's `rfdiffusion-fixed` into the RFdiffusion module (free, code only).
2. Enable FSx, load the databases, switch both arms' MSA to self-hosted (§5).
3. The 3-seed run: 3 seeds x 2 arms, whole pipeline, self-hosted MSA. **Ask Jelena first.**
4. N=100 if the 3-seed results warrant it. Not yet decided. **Ask Jelena first.**

The separate N=5 pilot is dropped: 3 seeds x 2 arms is 6 runs, enough to shake out wiring,
and it exercises the exact configuration the real run uses. Testing on the public API and
then switching to FSx would validate a stack we never actually run.

## 1. Decisions needed before any code changes

| # | Decision | Options | Notes |
|---|---|---|---|
| D1 | MSA source, both arms | **Decided 2026-10-28: both self-hosted.** No public API in either arm — on a hosted service you don't know what hardware you ran on, so you can't benchmark it. NIM arm: MSA Search NIM (GPU). Baseline arm: `colabfold_search` (CPU). Same databases from FSx, our own instances. | Needs §6. The NIM needs ≥2× 48 GB GPUs, i.e. `g6e.12xlarge` at $10.49/h. Expect GPU-vs-CPU on this step; state it in the write-up. |
| D2 | Baseline RFdiffusion container | **`rfdiffusion-fixed`** (Manuel, 2026-10-22): Bojan's image plus the NIM's `model_runners.py`, `util_module.py` and prebuilt TensorRT engines | Manuel reports the same seed now gives the same binder on both sides, stable across seeds. Not yet run through our Nextflow module (`run_inference.py` path), and the seed flags it needs are unconfirmed. Caveat for the write-up: the baseline now runs NIM code and NIM engines, so the RFdiffusion step measures only the serving layer. |
| D3 | Baseline ProteinMPNN container | `proteinmpnn` (stock, cannot be seeded) or `proteinmpnn-seed-patch-v2` with `--pmpnn_seed 102` (matches the NIM's own seed) | The stack-matched ProteinMPNN from plan v2 D1 was never built. No image in ECR. |
| D4 | Design space | Binder length `55-100` and hotspots `A56,A63,A113,A123,A124` (plan v2), or fixed `78` / `A56` (today's seed test) | A length range interacts with the TensorRT cache (F1): engines are built per length. |
| D5 | Primary endpoint | `interface_dG` or `iptm` | Pick before the run, not after. |
| D6 | RFdiffusion seed | `--rfd_random_seed 0` on both arms (agreed 2026-10-22) | Design N then uses seed N on both sides. |

## 2. Must fix

- [ ] **F1. RFdiffusion TensorRT cold start in the baseline arm.** Probably resolved by
  `rfdiffusion-fixed`, which ships the NIM's prebuilt engines. Confirm in the pilot that the
  first task does not spend ~31 min compiling; the rest of this item only applies if it does. Bojan assumed the cache
  stays warm on the instance, but in our pipeline it lives inside the container, which is new
  for every task. Every baseline design therefore pays the ~31 min build (1,851 s measured).
  At N=100 that is ~52 GPU-hours and ~$69. Fix: mount a host directory as the cache
  (`aws.batch.volumes` plus `XDG_CACHE_HOME`) so tasks on the same instance reuse it.
  Applies to `rfdiffusion-nim-code-updated`. Check whether the APDI image compiles at all.
  Still unmeasured: whether a cache built at one binder length helps another (the `DIFF_LEN`
  arm of `rfd_trt_cache_check.nf` never reported). That only matters if D4 keeps a range.
- [ ] **F2. Commit an N=100 run script.** `examples/pdl1-rfd/run-aws-batch-openfold-comparison.sh`
  is still N=1 with the old contigs, and has none of `--pmpnn_gpu true`, `--rfd_random_seed`,
  the container tags or the MSA setting. Write one script that takes N as an argument, so the
  N=5 pilot and the N=100 run differ only in that number.
- [ ] **F3. Hardware match for ProteinMPNN.** The baseline only gets a GPU with
  `--pmpnn_gpu true`. Without it the module sets `CUDA_VISIBLE_DEVICES=""`.
- [ ] **F4. Commit and push.** 9 modified files, 4 unpushed commits. Untracked:
  `benchmarks/`, `input/`, `rfd_noise_floor_check.nf`, `rfd_trt_cache_check.nf`,
  `assets/EMPTY_CACHE.tar` (0-byte placeholder for the cache check).
- [x] **F5. Lint.** No new errors in the benchmark path. The remaining errors are known:
  the conditional `include` in `main.nf` (kept for 24.04.3), plus pre-existing ones in
  `get_contigs.nf` and `silentfrompdbs.nf`.

## 3. AWS resources costing money now

| Resource | Cost | Action |
|---|---|---|
| `vol-0ff141f2624227a23`, 1,600 GB gp3, us-east-1a, attached to stopped `i-045eaf09b5dd828ef` (`g6.4xlarge`, "msa-rfd-gpu") | ~$4.27/day | Check whether the MSA databases are already on it. If they are, it can replace FSx under D1(b): change the stopped instance to `g6e.12xlarge` and serve from this volume. Otherwise delete it. |
| Root volume of the same instance | small | Goes with the instance. |
| SG rule `sgr-0b4f4f1fc88105a7c` (TCP 8000 from the VPC, "MSA NIM temporary") | none | Keep only if D1(b), remove after the run. |
| NGC API key | none | Rotate (it was used during debugging). |

## 4. The 3-seed run: what must pass

Serves as the pilot. 3 seeds x 2 arms, whole pipeline, self-hosted MSA.

- [ ] Both arms finish with 3/3 outputs at every stage (RFdiffusion, ProteinMPNN, relax,
  OpenFold3/AF2, scoring, `COMBINE_SCORES`).
- [ ] Seeds: design *i* used seed *i* on both arms (check the RFdiffusion configs and logs).
- [ ] With `rfdiffusion-fixed`, the RFdiffusion backbones match design-for-design between arms
  (Kabsch Cα RMSD ≈ 0), reproducing Manuel's result inside the pipeline.
- [ ] Baseline ProteinMPNN ran on a GPU (`nvidia-smi` in the task log, `CUDA_VISIBLE_DEVICES` not empty).
- [ ] TensorRT cache: the second and later baseline RFdiffusion tasks on an instance skip the
  ~31 min build.
- [ ] MSA: both arms self-hosted, neither touching `api.colabfold.com` (grep the task logs).
- [ ] Both arms' MSAs came from the same database files on FSx, and the alignment depths are
  in the same ballpark. Wildly different depths mean the search settings aren't matched.
- [ ] `of3_diffusion_samples` = 1 (the workflow enforces it).
- [ ] The primary endpoint (D5) appears in the combined score table.
- [ ] Per-process Batch timings collected, and N=100 cost extrapolated from them. Check it
  fits the remaining budget before asking for the N=100 go.
- [ ] MSA depths compared between arms (M7): if the NIM and colabfold_search return wildly
  different numbers of sequences, the search settings are still not matched.
- [ ] FSx read path timed (M8): is mmap off Lustre fast enough, or does the baseline arm
  need a high-memory queue?

## 5. Self-hosted MSA, both arms (D1)

Feasibility confirmed: OpenFold3 takes precomputed MSAs via `main_msa_file_paths` per chain
plus `--use_msa_server=False`
([docs](https://openfold-3.readthedocs.io/en/latest/precomputed_msa_how_to.html)). The query
sequence must be first in each `.a3m`, which `openfold3_msa.py finalise` already enforces.

Code, no AWS cost:

- [x] **M1.** `bin/openfold3_predict.py` — optional 5th argument, the MSA directory. Emits
  `main_msa_file_paths` per chain and passes `--use_msa_server=False`. A missing alignment is
  a hard error, so the run can't silently fall back to a web search and void the comparison.
- [x] **M2.** `modules/local/rfd/openfold3.nf` — `msas/*` input, passed on only when `.a3m`
  files are actually staged. Both call sites pass an empty list by default.
- [x] **M3.** `modules/local/rfd/openfold3_msa_local.nf` — `colabfold_search` in
  `quay.io/nf-core/proteinfold_colabfold:1.1.1`. Mirrors `OPENFOLD3_MSA`'s
  prepare/search/finalise shape so both arms carry the same non-search overhead in the timed
  task. **Databases are not staged** — `params.msa_db_dir` is a container path backed by the
  FSx mount, unlike `modules/local/common/mmseqs_colabfoldsearch.nf`, which stages them.
- [x] **M4.** `workflows/rfd_openfold.nf` — runs the local search when `--msa_db_dir` is set
  and hands the A3Ms to `OPENFOLD3`; unset, behaviour is exactly as before.

Two things in M3 that can only be confirmed by running it:

- [ ] **M3a.** `colabfold_search`'s unpacked A3M naming varies by version (query header vs
  index). The module accepts either and fails loudly with a directory listing otherwise.
  Confirm which on the first run and simplify.
- [ ] **M3b.** `openfold3_msa.py` needs Python ≥3.10. Verify the `proteinfold_colabfold`
  image satisfies that, or split prepare/finalise into the utils container — which would then
  need matching treatment on the NIM arm to keep the timed task symmetric.

Infrastructure, costs money — not before the run window:

- [ ] **M5.** FSx for Lustre, 2,400 GB, with UniRef30 and the ColabFold environmental DB.
  Confirmed the two arms want the *same* databases: the NIM's `uniref30_2302` and
  `colabfold_envdb_202108` are ColabFold's standard names, both MMseqs2 format. But the NGC
  copies ship pre-indexed for GPU Server (`**/*.idx`), which ColabFold's own
  `setup_databases.sh` layout may not match. ColabFold's pair is ~0.8–1 TB on disk, the NIM's
  `all` profile ~1.2 TB, so 2,400 GB holds both copies if one won't serve both. Download once,
  then test whether `colabfold_search` reads the NGC layout before duplicating.
- [x] **M6.** CDK: `iac/src/constructs/msa-cache.ts` in the infra repo (branch
  `feat/fsx-msa-cache`, commit `340faa5`), SCRATCH_2, off by default, with the launch
  templates installing `lustre-client` and mounting it. `aws.batch.volumes = ['/fsx:/fsx:ro']`
  added to both platform configs. A test asserts the default stays off.
  **Known limitation:** a Lustre filesystem lives in one subnet while the compute
  environments span four AZs, so three quarters of instances pay cross-AZ traffic to read it.
  Fine for a short run; would want revisiting otherwise.
- [x] **M7.** `params.msa_local_search_args` now carries `--align-eval 0.0001 --max-accept 100`,
  the NIM's own defaults ([API reference](https://docs.nvidia.com/nim/bionemo/msa-search/latest/api-reference.html)),
  rather than `colabfold_search`'s far looser 10 and 1000000. Without this the baseline would
  be handed a deeper alignment than the NIM by configuration alone.
  **Not fully matchable:** the two filter at different pipeline stages, the NIM's
  `max_msa_sequences` (500) trims per database with no direct `colabfold_search` equivalent,
  and sensitivity is not exposed by the NIM at all (only `search_type`). Validate empirically
  by comparing alignment depths on the pilot, and state the residual difference in the
  write-up.
- [ ] **M8. Baseline MSA memory — the open risk.** ColabFold sizes its index to main memory
  and expects it resident: ~128 GB for batched searches, 768 GB+ for single queries
  ([downloads page](https://colabfold.mmseqs.com/)). This pipeline searches one design at a
  time, and `cpu-small` tops out at `m5.2xlarge` (32 GB), so the default would not run.
  Mitigation in place: `params.msa_local_search_args` defaults to `--db-load-mode 2`, which
  mmaps the index off FSx instead of loading it. Measure this on the pilot. If it is too slow,
  the fallback is a high-memory compute environment (`r5.4xlarge`+), which is more CDK work
  and more cost — not more arguments.

  **This asymmetry is itself a result worth reporting.** The NIM keeps only cluster consensus
  sequences in VRAM (~8 GB UniRef30, ~36 GB envdb); the open-source path wants 128 GB+ of
  system RAM for the same search. That is a concrete difference in what each approach demands
  of the hardware, independent of speed.

## 6. N=100

Only if the 3-seed results warrant it - not a foregone conclusion.

- [ ] Jelena's explicit approval for the launch.
- [ ] Same script as the 3-seed run, N changed only.
- [ ] Afterwards, tear down anything created for the run (MSA server, storage, SG rule)
  the same day.
