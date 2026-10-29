# Parity audit: what differs between the two arms

2026-10-29. Every step compared, with what was done about it. A benchmark is
only worth running if the single difference between the arms is the thing being
measured.

## Status after the fixes

| Step | Baseline | NIM | Matched? |
|---|---|---|---|
| RFdiffusion backbone | `rfdiffusion-fixed` standalone | RFdiffusion NIM | **yes** — verified 0.0000 Å, byte-identical |
| MPNN checkpoint | ~~v_48_020~~ → **v_48_002** | v_48_002 (fixed) | **fixed** |
| MPNN seed | 102 | 102 (fixed) | yes |
| MPNN sampling temp | 1e-6 | 1e-6 | yes |
| MPNN model type | vanilla | vanilla (`use_soluble_model: false`) | yes |
| MPNN passes | ~~2~~ → **1** | 1 | **fixed** |
| Backbone MPNN designs on | ~~relaxed~~ → **raw** | raw | **fixed** |
| FastRelax | `RELAX_ONLY` | `THREAD_AND_RELAX` | **fixed** — same container, same XML, same resources |
| `omit_AAs` | `CX` | not exposed by the NIM API | **no** — see below |
| MSA | OpenFold3's internal ColabFold call | `colabfold_remote_msa.py` | **no** — see below |
| Fold | OpenFold3 v0.5 | OpenFold3 NIM | n/a — this is what is being measured |
| Scoring | `BINDCRAFT_SCORING` | `BINDCRAFT_SCORING` | yes — same process, same arguments |

## What was fixed, and why it mattered

### ProteinMPNN checkpoint

`dl_interface_design.py` defaults to `v_48_020`. The NIM reports `v_48_002` in
its own FASTA header and its API exposes no checkpoint parameter, so the
baseline is what moves. The 3-seed run was built on this mismatch, which is why
sequence identity came out at 40.1% — October's decomposition put an unmatched
checkpoint at ~47% identity against ~70% matched.

Fix: `--pmpnn_weights /app/dl_binder_design/mpnn_fr/ProteinMPNN/vanilla_model_weights/v_48_002.pt`

### Number of MPNN passes, and what they design against

This is the larger one and it was not visible from the run script. From
`dl_interface_design.py`:

```
for cycle in range(args.relax_cycles):
    seqs_scores = self.sequence_optimize(sample_feats)
    self.relax_pose(sample_feats)
seqs_scores = self.sequence_optimize(sample_feats)
```

So `relax_cycles=N` gives `N+1` MPNN passes, and the last one designs against an
**already-relaxed** backbone. `relax_cycles=1` is therefore 2 passes, not 1. The
NIM arm does one pass against the **raw** RFdiffusion backbone and relaxes
afterwards.

Setting `relax_cycles=0` alone does not fix it: that path threads and dumps with
no relax at all, so the baseline would skip a step the NIM arm performs.

Fix: `--pmpnn_relax_cycles 0 --pmpnn_external_relax true`. The new `RELAX_ONLY`
process applies `RosettaFastRelaxUtil.xml` from the same container
`THREAD_AND_RELAX` uses, with resources matched to it in
`conf/platforms/aws_batch_openfold.config`. Both arms are now:

> MPNN (one pass, raw backbone) → thread → FastRelax

## What is still not matched

### `omit_AAs`

The baseline forbids cysteine and X (`CX`). The ProteinMPNN NIM's API accepts
only `input_pdb`, `input_pdb_chains`, `num_seq_per_target`, `sampling_temp`,
`use_soluble_model` and `ca_only` — there is no equivalent, and no way to learn
what it does internally.

Not fixable from our side. In practice it did not bite on the 3-seed run:
**zero cysteines in any design on either arm**, which is expected at a sampling
temperature of 1e-6. Worth re-checking on any larger run rather than assuming.

### MSA

Both arms reach the same public ColabFold API, but by different code paths: the
baseline through OpenFold3's own internal call, the NIM arm through
`bin/colabfold_remote_msa.py`. Confirmed from the run logs — the baseline ran
`OPENFOLD3` with no `OPENFOLD3_MSA` task.

`--msa_shared_remote` exists to close this and routes both through
`OPENFOLD3_MSA`, but it fails: it feeds OpenFold3 `main_msa_file_paths`, which
the current docs describe but OpenFold3 v0.5 does not honour, giving an
`IndexError` in `parse_msas`. Worth retesting against a newer OpenFold3 build
before the N=100 run.

Until then the two MSAs are not guaranteed identical, only drawn from the same
service. This is the remaining known confounder.

## Re-run needed

The 3-seed numbers were produced before these fixes. Sequence identity,
`interface_dG`, `binder_score` and `iptm` all carry the checkpoint and
protocol mismatch, so they should not be quoted as a NIM-vs-baseline result.
Re-run the baseline arm (~20-30 min; the NIM arm is unchanged and its outputs
remain valid).
