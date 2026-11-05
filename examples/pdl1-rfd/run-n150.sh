#!/bin/bash
# N=150 quality run: no-NIM (rfdiffusion-fixed) vs NIM, matched backbones.
#
# Both arms run the same RFdiffusion implementation, so backbones come out
# bit-identical between arms and the comparison is paired rather than
# two independent groups. Fixed binder length removes length as a confound.
#
# OpenFold3 is deliberately NOT batched: batching shifts folds unevenly
# between arms (1.27 A open source, 0.35 A NIM, against a 0.08 A noise
# floor), which would land an arm-specific artefact on the metrics being
# compared. Speed claims come from the inference-only figures and the
# batched N=5 run instead.
set -uo pipefail
cd "$(dirname "$0")"

SEEDS=$(python3 -c "print(','.join(str(i) for i in range(150)))")

CES="BatchGpuStandardSpotComp-lyUM0r98RuPk3XfF BatchGpuStandardOnDemand-KTsraE3kTx0Qmkoh
     BatchCpuSmallSpotCompute-zVc4X6VqMErTtKtm BatchCpuSmallOnDemandCom-zSr72sqIo5nqaPX5"
set_compute() {
  for ce in ${CES}; do
    aws batch update-compute-environment --profile lokalabs-nims --region us-east-1 \
      --compute-environment "${ce}" --state "$1" >/dev/null 2>&1 && echo "$1 ${ce}"
  done
}
trap 'set_compute DISABLED' EXIT

COMMON=(
  ../../main.nf
  --input_pdb input/PDL1.pdb
  --contigs "[A18-132/0 78-78]"
  --hotspot_res A56,A63,A113,A123,A124
  --rfd_n_designs=150
  --rfd_seeds="${SEEDS}"
  --pmpnn_seqs_per_struct=1
  --pmpnn_relax_cycles=0
  --pmpnn_external_relax=true
  --pmpnn_weights /app/dl_binder_design/mpnn_fr/ProteinMPNN/vanilla_model_weights/v_48_002.pt
  --pmpnn_gpu true
  --pmpnn_container_tag proteinmpnn-seed-patch-v2
  --pmpnn_seed=102
  --of3_batch_size=1
  --msa_target_a3m ../../assets/msa/pdl1_target.a3m
  -with-trace -with-report -with-timeline
)

set_compute ENABLED
sleep 20
TAG=$(date -u +%Y%m%dT%H%M%SZ)
echo "N150_TAG=${TAG}"

# Arm 1: no-NIM, rfdiffusion-fixed (same implementation the NIM runs)
./run-with-credential-refresh.sh "n150-${TAG}-nonim.log" \
  "${COMMON[@]}" --method rfd_openfold --rfd_standalone true \
  --outdir "s3://nvidia-nims-output/n150-${TAG}/nonim" \
  -profile aws_batch_openfold
a=$?; echo "ARM_NONIM_EXIT=${a}"
if [ "${a}" -ne 0 ]; then echo "NO-NIM ARM FAILED - stopping"; exit 1; fi

sleep 30

# Arm 2: NIM
./run-with-credential-refresh.sh "n150-${TAG}-nim.log" \
  "${COMMON[@]}" --method rfd_nim --of3_diffusion_samples=1 \
  --outdir "s3://nvidia-nims-output/n150-${TAG}/nim" \
  -profile aws_batch_nims
echo "ARM_NIM_EXIT=$?"
echo "N150 DONE"
