#!/bin/bash

set -euo pipefail

# NIM smoke test on AWS Batch — the bundled PD-L1 campaign, same input/contigs/
# hotspot as run-aws-batch.sh, but routed through the NIM path:
# RFdiffusion NIM -> ProteinMPNN NIM -> thread/relax -> unpaired A/B MSA
# search -> OpenFold3 NIM -> BindCraft-derived scoring.
#
# Deliberately smaller than the baseline's 4 x 2 = 8 candidates: every NIM task
# boots its own server and pulls model weights on a cold start, so 2 x 1 = 2
# candidates is enough to prove outputs come back without paying that cost
# eight times over.
#
# Requires:
#   - conf/platforms/aws_batch_nims.config pointed at the deployed queue/bucket
#     values — see that file for details
#   - `aws_batch_nims` configured with an AWS Secrets Manager secret containing
#     the NGC API key. NIM tasks fetch it at runtime without writing it to their
#     Nextflow work scripts.

PIPELINE_DIR=../../

export AWS_PROFILE="${AWS_PROFILE:-lokalabs-nims}"

# main.nf uses conditional `include` statements (inside if/else blocks) for method
# dispatch, which Nextflow's newer strict syntax parser (v2, default since ~26.x)
# rejects with "Unexpected input: 'include'". Force the classic v1 parser until
# main.nf's dispatch logic is restructured to be strict-parser-compatible.
export NXF_SYNTAX_PARSER=v1

nextflow run "${PIPELINE_DIR}/main.nf" \
  --method rfd_nim \
  --input_pdb 'input/*.pdb' \
  --outdir s3://nvidia-nims-output/pdl1-rfd-nim-smoke-test \
  --contigs "[A18-132/0 65-120]" \
  --hotspot_res "A56" \
  --rfd_n_designs=2 \
  --pmpnn_seqs_per_struct=1 \
  -profile aws_batch_nims \
  -resume
