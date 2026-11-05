#!/bin/bash
# N=30 NIM arm, batched, to measure what one NIM server boot per batch buys.
#
# RFdiffusion and ProteinMPNN run on their benchmark images. Their weight-cached
# builds are not used here: rfdiffusion-nim-cached never becomes ready (the
# server stalls past 300 s where the benchmark image boots in ~75 s), and
# proteinmpnn-nim-cached has never been started at all. openfold3-nim-cached is
# the one cached image that has been boot-tested, so it is the only one in.
#
# Batching makes the uncached images affordable anyway: 2 RFdiffusion tasks
# pull the NGC weights twice, not thirty times.
#
# Seeds 0-29 match the first 30 designs of the N=150 run, so the structures are
# comparable. Not a quality run - N=30 is too small, and ProteinMPNN's seed is
# not portable between arms.
set -uo pipefail
cd "$(dirname "$0")"

GUARD="${1:?usage: run-batch-validation.sh <cost-guard.config>}"
SEEDS=$(python3 -c "print(','.join(str(i) for i in range(30)))")

CES="BatchGpuStandardSpotComp-lyUM0r98RuPk3XfF BatchGpuStandardOnDemand-KTsraE3kTx0Qmkoh
     BatchCpuSmallSpotCompute-zVc4X6VqMErTtKtm BatchCpuSmallOnDemandCom-zSr72sqIo5nqaPX5"

# Terminates instances, not just the queues - see stop-all-compute.sh. Runs on
# success, failure and interrupt alike.
trap './stop-all-compute.sh' EXIT

ECR=520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims

for ce in ${CES}; do
  aws batch update-compute-environment --profile lokalabs-nims --region us-east-1 \
    --compute-environment "${ce}" --state ENABLED >/dev/null 2>&1 && echo "ENABLED ${ce}"
done
sleep 20
TAG=$(date -u +%Y%m%dT%H%M%SZ)
echo "BATCHVAL_TAG=${TAG}"

./run-with-credential-refresh.sh "batchval-${TAG}-nim.log" \
  ../../main.nf \
  --method rfd_nim \
  --input_pdb input/PDL1.pdb \
  --contigs "[A18-132/0 78-78]" \
  --hotspot_res A56,A63,A113,A123,A124 \
  --rfd_n_designs=30 \
  --rfd_seeds="${SEEDS}" \
  --rfd_batch_size=15 \
  --of3_batch_size=15 \
  --of3_diffusion_samples=1 \
  --pmpnn_seqs_per_struct=1 \
  --pmpnn_relax_cycles=0 \
  --pmpnn_external_relax=true \
  --pmpnn_gpu true \
  --pmpnn_seed=102 \
  --openfold3_nim_image "${ECR}:openfold3-nim-cached" \
  --msa_target_a3m ../../assets/msa/pdl1_target.a3m \
  --outdir "s3://nvidia-nims-output/batchval-${TAG}/nim" \
  -profile aws_batch_nims \
  -c "${GUARD}" \
  -with-trace -with-report -with-timeline
echo "WRAPPER_EXIT=$?"

# errorStrategy is 'ignore', so Nextflow exits 0 even when tasks failed. The
# trace is the only honest record of whether the run actually produced designs.
TRACE=$(ls -t trace*.txt 2>/dev/null | head -1)
if [ -n "${TRACE}" ]; then
  echo "=== task outcomes (${TRACE}) ==="
  awk -F'\t' 'NR==1{for(i=1;i<=NF;i++) if($i=="status") s=i; next}
              {c[$s]++} END{for (k in c) printf "  %-12s %d\n", k, c[k]}' "${TRACE}"
fi
echo "BATCHVAL DONE tag=${TAG}"
