#!/bin/bash
#
# NIM vs no-NIM benchmark, both arms, whole pipeline.
#
#   ./run-benchmark.sh 3                      # the 3-seed shakedown
#   SEEDS=1,15,30 ./run-benchmark.sh 3        # a different seed set
#   ./run-benchmark.sh 100                    # needs explicit sign-off first
#
# N_DESIGNS must equal the number of seeds.
#
# The two arms differ ONLY in which implementation runs each step. Everything
# that could otherwise explain a difference is pinned here rather than left to
# a default, so the run is reproducible from this file alone.
set -euo pipefail

N_DESIGNS="${1:?usage: run-benchmark.sh <n_designs>}"
RUN_TAG="${RUN_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"

PIPELINE_DIR=../../
export AWS_PROFILE="${AWS_PROFILE:-lokalabs-nims}"
export NXF_SYNTAX_PARSER=v1

# --- shared design space -----------------------------------------------------
# A range rather than a fixed 78: published PD-L1 minibinders are 50-80
# residues, so a fixed 78 sits at the top of the band and removes the length
# variation RFdiffusion is normally allowed to explore.
CONTIGS="[A18-132/0 55-100]"
# Five hotspots spread across the interface rather than A56 alone, as published
# PD-L1 campaigns do. R113 in particular forms a salt bridge with PD-1 Glu136.
HOTSPOTS="A56,A63,A113,A123,A124"
INPUT_PDB='input/PDL1.pdb'

# --- matching between the arms -----------------------------------------------
# Explicit seeds rather than consecutive ones, so this run is continuous with
# the 2026-10-22 NIM-vs-no-NIM comparison, which used these three. Both
# pipelines get the same list, so designs pair up one for one.
SEEDS="${SEEDS:-0,5,34,42,77}"
N_SEEDS=$(awk -F, '{print NF}' <<<"${SEEDS}")
if [ "${N_DESIGNS}" != "${N_SEEDS}" ]; then
    echo "N_DESIGNS=${N_DESIGNS} but SEEDS has ${N_SEEDS} entries (${SEEDS})" >&2
    echo "Pass SEEDS= with one seed per design, e.g. SEEDS=0,5,34 ./run-benchmark.sh 3" >&2
    exit 1
fi
# MSA mode. "local" searches self-hosted databases on the FSx mount, and both
# arms run the identical module, so the MSA step contributes nothing to the
# comparison.
#
# "remote" is NOT matched. --msa_shared_remote was meant to route both arms
# through OPENFOLD3_MSA, but it hands OpenFold3 main_msa_file_paths, which
# v0.5 does not honour: every OPENFOLD3 task died with an IndexError in
# parse_msas on 2026-10-29. So it is not passed here. The baseline instead
# makes its own ColabFold call from inside OpenFold3 while the NIM arm uses
# bin/colabfold_remote_msa.py - same service, different code path. This is the
# one remaining unmatched step; see benchmarks/parity-audit.md.
MSA_MODE="${MSA_MODE:-remote}"
# The ColabFold-format databases colabfold_search reads, NOT /fsx/msa, which
# held NVIDIA's GPU-format copy that stock MMseqs2 cannot open.
MSA_DB_DIR=/fsx/colabfold-db
# One MPNN pass and one relax on both sides.
#
# dl_binder_design's MPNN-FastRelax does relax_cycles+1 MPNN passes, and its
# final pass designs against an already-relaxed backbone. The NIM arm does one
# pass against the raw backbone and relaxes afterwards. So relax_cycles=1 is
# still 2 passes against 1, designing on a different backbone - matching the
# cycle count is not enough. Instead: 0 cycles for a single pass, then
# RELAX_ONLY, which is THREAD_AND_RELAX's container, XML and resources.
RELAX_CYCLES=0
EXTERNAL_RELAX=true
# The NIM reports seed=102 and checkpoint v_48_002 in its own FASTA header;
# the seed-patch image is the only baseline build that accepts -seed. The NIM's
# API exposes neither, so the baseline is what moves to match it. The baseline
# otherwise defaults to v_48_020 - a different checkpoint, which on its own
# cost ~27 points of sequence identity in the 2026-10-29 3-seed run.
PMPNN_SEED=102
PMPNN_WEIGHTS=/app/dl_binder_design/mpnn_fr/ProteinMPNN/vanilla_model_weights/v_48_002.pt
PMPNN_CONTAINER=proteinmpnn-seed-patch-v2

# The arms run strictly sequentially. They share one GPU Spot pool, so running
# them together would mean the "faster" arm is whichever got scheduled.

echo "=== baseline arm: N=${N_DESIGNS}, tag ${RUN_TAG} ==="
./run-with-credential-refresh.sh "benchmark-${RUN_TAG}-baseline.log" \
  "${PIPELINE_DIR}/main.nf" \
  --method rfd_openfold \
  --input_pdb "${INPUT_PDB}" \
  --outdir "s3://nvidia-nims-output/benchmark-${RUN_TAG}/baseline" \
  --contigs "${CONTIGS}" \
  --hotspot_res "${HOTSPOTS}" \
  --rfd_n_designs="${N_DESIGNS}" \
  --rfd_seeds="${SEEDS}" \
  --rfd_standalone true \
  --pmpnn_seqs_per_struct=1 \
  --pmpnn_relax_cycles="${RELAX_CYCLES}" \
  --pmpnn_external_relax="${EXTERNAL_RELAX}" \
  --pmpnn_weights "${PMPNN_WEIGHTS}" \
  --pmpnn_gpu true \
  --pmpnn_container_tag "${PMPNN_CONTAINER}" \
  --pmpnn_seed="${PMPNN_SEED}" \
  $([ "${MSA_MODE}" = local ] && echo "--msa_db_dir ${MSA_DB_DIR}" || true) \
  -profile aws_batch_openfold

echo "=== NIM arm: N=${N_DESIGNS}, tag ${RUN_TAG} ==="
./run-with-credential-refresh.sh "benchmark-${RUN_TAG}-nim.log" \
  "${PIPELINE_DIR}/main.nf" \
  --method rfd_nim \
  --input_pdb "${INPUT_PDB}" \
  --outdir "s3://nvidia-nims-output/benchmark-${RUN_TAG}/nim" \
  --contigs "${CONTIGS}" \
  --hotspot_res "${HOTSPOTS}" \
  --rfd_n_designs="${N_DESIGNS}" \
  --rfd_seeds="${SEEDS}" \
  --pmpnn_seqs_per_struct=1 \
  --of3_diffusion_samples=1 \
  $([ "${MSA_MODE}" = local ] && echo "--msa_db_dir ${MSA_DB_DIR} --msa_use_nim false" || true) \
  -profile aws_batch_nims

echo "=== done: s3://nvidia-nims-output/benchmark-${RUN_TAG}/ ==="
