# RFdiffusion with local OpenFold3

`--method rfd_openfold` runs the non-NIM comparison path:

```text
RFdiffusion → ProteinMPNN with Rosetta threading/FastRelax → OpenFold3 → BindCraft-derived scoring
```

The OpenFold3 wrapper receives each threaded complex PDB and extracts chain A
(binder) and chain B (cropped target) sequences. The model folds those sequences
with independent per-chain MSAs; paired MSA search is disabled. PDB coordinates
are not supplied as an initial guess or template.

The local OpenFold3 process uses `run_openfold predict`, saves the first predicted
PDB and records aggregate pLDDT, pTM, ipTM and gPDE. Every prediction proceeds to
the same BindCraft-derived scorer used by `rfd_nim`; there is no confidence
filter.

## AWS Batch

Use the `aws_batch_openfold` profile for the repository's AWS deployment:

```bash
export AWS_PROFILE="${AWS_PROFILE:-lokalabs-nims}"
export NXF_SYNTAX_PARSER=v1

nextflow run main.nf \
  --method rfd_openfold \
  --input_pdb 'examples/pdl1-rfd/input/*.pdb' \
  --outdir s3://nvidia-nims-output/pdl1-rfd-openfold \
  --contigs "[A18-132/0 78-78]" \
  --hotspot_res "A56" \
  --rfd_n_designs=1 \
  --pmpnn_seqs_per_struct=1 \
  --pmpnn_relax_cycles=1 \
  -profile aws_batch_openfold
```

The OpenFold3 job requests one GPU, eight CPUs, 64 GB memory and 16 GiB shared
memory. ProteinMPNN/Rosetta and BindCraft scoring run on the CPU queue.

## Comparison with `rfd_nim`

The two workflows perform the same sequence of scientific tasks, but use local
RFdiffusion, ProteinMPNN and OpenFold3 execution here and NIM API execution in
`rfd_nim`. Local OpenFold3 generates its MSAs inside the prediction process;
`rfd_nim` generates and saves the two A3Ms in a separate CPU task. Exact designs,
alignments and predictions are not guaranteed to match because generation is
stochastic and the OpenFold3 runtimes use different packaged releases.

For timing comparisons, run the workflows sequentially with the same inputs and
design counts. The local OpenFold3 task includes MSA time, while the corresponding
NIM time is the sum of its separate MSA and OpenFold3 NIM tasks.

The bundled PD-L1 comparison can be reproduced from `examples/pdl1-rfd` with:

```bash
./run-aws-batch-openfold-comparison.sh
```

The script runs the one-design local workflow to completion before submitting
the NIM workflow. It deliberately omits `-resume` so a timing run does not reuse
previous task results.
