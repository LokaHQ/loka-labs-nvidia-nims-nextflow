#!/bin/bash

# Baseline (no NIMs) smoke test on AWS Batch — the bundled PD-L1 campaign, same
# input/contigs/hotspot as run-local-simple.sh, run via -profile aws_batch instead of
# -profile local. rfd_n_designs=4 x pmpnn_seqs_per_struct=2 = 8 candidates.
#
# Requires conf/platforms/aws_batch.config to be pointed at the deployed queue/bucket
# values — see that file for details.

PIPELINE_DIR=../../

# main.nf uses conditional `include` statements (inside if/else blocks) for method
# dispatch, which Nextflow's newer strict syntax parser (v2, default since ~26.x)
# rejects with "Unexpected input: 'include'". Force the classic v1 parser until
# main.nf's dispatch logic is restructured to be strict-parser-compatible.
export NXF_SYNTAX_PARSER=v1

nextflow run ${PIPELINE_DIR}/main.nf \
  --method rfd \
  --input_pdb 'input/*.pdb' \
  --outdir s3://nvidia-nims-output/pdl1-rfd-smoke-test \
  --contigs "[A18-132/0 65-120]" \
  --hotspot_res "A56" \
  --rfd_n_designs=4 \
  --pmpnn_seqs_per_struct=2 \
  -profile aws_batch \
  -resume
