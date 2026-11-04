#!/bin/bash
#
# Build and push the weight-cached NIM images to ECR under NEW tags.
#
# These never overwrite the tags that ran the N=150 benchmark; each cached
# image is built FROM its benchmark tag, so the cache is the only difference.
#
# Needs cache/<nim>-nim to exist first - run populate-cache.sh on a
# linux/amd64 host. This step only adds COPY and ENV layers, so it is safe to
# run on an Apple Silicon Mac under buildx emulation.
#
#   ./build.sh                  # build, verify, push all three
#   PUSH=0 ./build.sh           # build and verify only
#   ./build.sh openfold3        # just one
set -euo pipefail

ACCOUNT="${ACCOUNT:-520168724997}"
REGION="${REGION:-us-east-1}"
REPO="${REPO:-nvidia-nims}"
PUSH="${PUSH:-1}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

cd "$(dirname "$0")"

# Tags we must never clobber - these produced the published results.
PROTECTED="rfdiffusion-nim proteinmpnn-nim openfold3-nim rfdiffusion-fixed proteinmpnn-seed-patch-v2 openfold3-v0.5-pixi bindcraft nf-binder-design-utils"

build_one() {
    local nim="$1"
    local tag="${nim}-nim-cached"
    local image="${REGISTRY}/${REPO}:${tag}"

    for p in ${PROTECTED}; do
        if [ "${tag}" = "${p}" ]; then
            echo "refusing to build over protected tag ${tag}" >&2
            exit 1
        fi
    done

    if [ ! -d "cache/${nim}-nim" ]; then
        echo "cache/${nim}-nim is missing - run populate-cache.sh first" >&2
        exit 1
    fi

    echo "=== building ${image} ==="
    docker build --platform linux/amd64 \
        -f "Dockerfile.${tag}" -t "${image}" .

    echo "=== verifying the cache is in the image ==="
    docker run --rm --platform linux/amd64 --entrypoint sh "${image}" \
        -c 'test -d /opt/nim-cache && du -sh /opt/nim-cache && [ -n "$(ls -A /opt/nim-cache)" ]'

    if [ "${PUSH}" = "1" ]; then
        echo "=== pushing ${image} ==="
        docker push "${image}"
        echo "pushed ${image}"
    fi
}

TARGETS=("$@")
if [ "${#TARGETS[@]}" -eq 0 ]; then
    TARGETS=(rfdiffusion proteinmpnn openfold3)
fi

if [ "${PUSH}" = "1" ]; then
    aws ecr get-login-password --region "${REGION}" \
        | docker login --username AWS --password-stdin "${REGISTRY}"
fi

for t in "${TARGETS[@]}"; do
    build_one "${t}"
done
