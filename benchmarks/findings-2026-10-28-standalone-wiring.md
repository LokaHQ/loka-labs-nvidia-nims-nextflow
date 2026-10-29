# rfdiffusion-fixed in the pipeline — wiring check

2026-10-28. Branch `benchmark/openfold-vs-nim`. One design, seed 0, both arms,
`rfd_standalone_wiring_check.nf` with `-profile aws_batch_nims -c ad_hoc_standalone_wiring.config`.

## Result

| | |
|---|---|
| Backbone RMSD, standalone vs NIM | **0.00 Å** over 193 residues, pruned and all-atom |
| Output PDB SHA-256 | `e0742b5e294e7688…` — **identical to the 24 Oct reference run** |
| Checkpoint SHA-256 | `76e4e260aefee3b5…`, same on both sides |

Not merely equal to two decimal places: the same bytes. The reference 15-seed parity
result reproduces inside the pipeline.

## Timing

| Task | Wall clock |
|---|---|
| `RFDIFFUSION_STANDALONE` | 1 m 37 s |
| `RFDIFFUSION_NIM` | 1 m 33 s |

The standalone arm breaks down as ~21 s model download, 52.6 s warmup, 16.9 s inference.
The two arms are within 4 s of each other, and no engine build happened on either —
`rfdiffusion-fixed` ships prebuilt SM89 engines, so the ~31 min cold start that dominated
the old baseline is gone.

## What the image actually needs

Read off the reference run's own wrapper and metadata rather than guessed:

- **Weights are not in the image.** The NIM fetches them when its server starts; nothing
  does that in the standalone path. The module now downloads them with the NIM's own
  `nimlib` downloader into a task-local `NIM_CACHE_PATH`, then **unsets the NGC key** so
  inference cannot reach NGC and quietly differ from a run without one.
- **The warmup is required for parity**, not optional. The reference run carried it, and
  its metadata records it: `/opt/nim/5TPN.pdb`, 350 residues, 15 steps, seed 1234. It is
  now the default. Costs 52.6 s per design, because every task is a fresh container.
- **L40S only.** The engines are `sm89` (`2.3.0-l800_sm89_v1`, 333 `.trt` files per
  checkpoint). `gpu-standard` is g6e, so this holds, but anything else will not find
  usable engines.

## Consequences

**Per-design overhead is now larger than the inference it wraps.** 21 s download + 53 s
warmup for 17 s of work. At N=100 that is roughly 2 GPU-hours of overhead on the baseline
arm alone. The NIM arm pays its own startup per task, which is why the two land within 4 s,
so the comparison stays fair — but both are dominated by setup, and any speed claim must
say so.

**Mounting the NIM cache on FSx would remove the 21 s download from both arms.** The
filesystem is already planned for the MSA databases; this is a second use for it.

**For the write-up:** the original pilot's "NIM is ~20x faster" was the TensorRT engine
build in the old APDI container, not the NIM being faster. With engines prebuilt on both
sides, RFdiffusion is the same speed to within 4 s, and produces identical output.

## Still open

- Whether the warmup is genuinely load-bearing or merely incidental. It was present in the
  reference run and is kept for that reason; nobody has run the pair without it. One run
  with `--rfd_nim_warmup_pdb false` would settle it and save 53 s per design if it is not
  needed.
