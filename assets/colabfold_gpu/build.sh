#!/bin/bash
#
# Build and push the GPU-capable colabfold_search image to ECR.
#
# Needs a working Docker daemon and linux/amd64. On an Apple Silicon Mac,
# buildx emulates amd64 - slow but it works. There is no AWS cost in building
# locally; pushing to ECR costs only the storage.
#
#   ./build.sh            # build, verify, push
#   PUSH=0 ./build.sh     # build and verify only
set -euo pipefail

ACCOUNT="${ACCOUNT:-520168724997}"
REGION="${REGION:-us-east-1}"
REPO="${REPO:-nvidia-nims}"
TAG="${TAG:-colabfold-gpu}"
PUSH="${PUSH:-1}"
IMAGE="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:${TAG}"

cd "$(dirname "$0")"

echo "=== building ${IMAGE} ==="
docker build --platform linux/amd64 -t "${IMAGE}" .

# The Dockerfile already asserts both versions at build time; repeat it here so
# a cached layer cannot hide a bad image.
echo "=== verifying ==="
docker run --rm --platform linux/amd64 "${IMAGE}" mmseqs version
docker run --rm --platform linux/amd64 "${IMAGE}" sh -c "colabfold_search --help | grep -- --gpu"

if [ "${PUSH}" = "1" ]; then
    echo "=== pushing ==="
    aws ecr get-login-password --region "${REGION}" \
        | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
    docker push "${IMAGE}"
    echo "pushed ${IMAGE}"
fi

cat <<'NOTE'

Next, to actually run a GPU search:

  1. The GPU search needs a GPU-format database. Ours was converted to CPU
     format and then deleted with FSx, so this means re-downloading ColabFold's
     prebuilt uniref30_2302 (~100 GB, roughly $5 of NAT transfer) and keeping
     its indices - GPU search holds them in GPU memory.

         setup_databases.sh with GPU=1, or the prebuilt db as shipped

  2. Point the search at it with --gpu 1. That means "use GPU", not "use one
     GPU"; MMseqs2 takes every visible device unless CUDA_VISIBLE_DEVICES says
     otherwise.

  3. One GPU is enough. MMseqs2 streams databases larger than GPU memory at
     about 63-65% of in-memory speed, so this runs on the gpu-standard Spot
     queue rather than needing the two 48 GB GPUs the MSA Search NIM requires.
NOTE
