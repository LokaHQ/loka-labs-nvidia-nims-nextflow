#!/bin/bash

# Baseline (no NIMs) smoke test on AWS Batch — the bundled PD-L1 campaign, same
# input/contigs/hotspot as run-local-simple.sh, run via -profile aws_batch instead of
# -profile local. rfd_n_designs=4 x pmpnn_seqs_per_struct=2 = 8 candidates.
#
# Requires conf/platforms/aws_batch.config to have real queue/bucket values (not the
# AWS_BATCH_*_PLACEHOLDER defaults) — see that file for details.

PIPELINE_DIR=../../

nextflow run ${PIPELINE_DIR}/main.nf \
  --method rfd \
  --input_pdb 'input/*.pdb' \
  --outdir results \
  --contigs "[A18-132/0 65-120]" \
  --hotspot_res "A56" \
  --rfd_n_designs=4 \
  --pmpnn_seqs_per_struct=2 \
  -profile aws_batch \
  -resume
