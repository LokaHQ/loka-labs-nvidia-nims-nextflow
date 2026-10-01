#!/bin/bash

set -euo pipefail

# Reproduce the one-design PD-L1 comparison sequentially so the two workflows
# do not compete for AWS Batch capacity.

PIPELINE_DIR=../../

export AWS_PROFILE="${AWS_PROFILE:-lokalabs-nims}"
export NXF_SYNTAX_PARSER=v1

nextflow run "${PIPELINE_DIR}/main.nf" \
  --method rfd_openfold \
  --input_pdb 'input/*.pdb' \
  --outdir s3://nvidia-nims-output/pdl1-rfd-openfold-baseline \
  --contigs "[A18-132/0 78-78]" \
  --hotspot_res "A56" \
  --rfd_n_designs=1 \
  --pmpnn_seqs_per_struct=1 \
  --pmpnn_relax_cycles=1 \
  -profile aws_batch_openfold

nextflow run "${PIPELINE_DIR}/main.nf" \
  --method rfd_nim \
  --input_pdb 'input/*.pdb' \
  --outdir s3://nvidia-nims-output/pdl1-rfd-openfold-nim \
  --contigs "[A18-132/0 78-78]" \
  --hotspot_res "A56" \
  --rfd_n_designs=1 \
  --pmpnn_seqs_per_struct=1 \
  --of3_diffusion_samples=1 \
  -profile aws_batch_nims
