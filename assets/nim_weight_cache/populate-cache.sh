#!/bin/bash
#
# Fill cache/<nim> with the model weights each NIM downloads from NGC, by
# starting the server once and letting it do the download itself. We do not
# guess an internal download command - this uses the same code path the
# pipeline already exercises.
#
# MUST run on a linux/amd64 host. The NIMs are amd64 CUDA images, so this will
# not work on an Apple Silicon Mac. Whether a GPU is also required is the open
# question - see README.md; try a CPU-only box first, it is far cheaper.
#
#   ./populate-cache.sh                 # all three
#   ./populate-cache.sh rfdiffusion     # just one
set -euo pipefail

ACCOUNT="${ACCOUNT:-520168724997}"
REGION="${REGION:-us-east-1}"
REPO="${REPO:-nvidia-nims}"
SECRET="${SECRET:-nvidia-nims/ngc-api-key}"
READY_CHECKS="${READY_CHECKS:-180}"
GPU_FLAG="${GPU_FLAG:---gpus all}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

cd "$(dirname "$0")"

NGC_API_KEY="${NGC_API_KEY:-$(aws secretsmanager get-secret-value \
    --secret-id "${SECRET}" --region "${REGION}" \
    --query SecretString --output text)}"
if [ -z "${NGC_API_KEY}" ]; then
    echo "NGC_API_KEY is unavailable" >&2
    exit 1
fi
export NGC_API_KEY

aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}"

populate() {
    local nim="$1"
    local image="${REGISTRY}/${REPO}:${nim}-nim"
    local dest="cache/${nim}-nim"
    local name="populate-${nim}"

    echo "=== ${nim}: pulling ${image} ==="
    docker pull "${image}"

    rm -rf "${dest}"
    mkdir -p "${dest}"

    echo "=== ${nim}: starting server to trigger the download ==="
    # shellcheck disable=SC2086
    docker run -d --name "${name}" ${GPU_FLAG} \
        -e NGC_API_KEY \
        -e NIM_CACHE_PATH=/opt/nim-cache \
        -v "${PWD}/${dest}:/opt/nim-cache" \
        "${image}" /opt/nim/start_server.sh >/dev/null

    local ready=0
    for i in $(seq 1 "${READY_CHECKS}"); do
        if docker exec "${name}" curl -sf http://localhost:8000/v1/health/ready >/dev/null 2>&1; then
            echo "${nim}: server ready after ${i} check(s)"
            ready=1
            break
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" != "true" ]; then
            echo "${nim}: container exited before becoming ready" >&2
            break
        fi
        sleep 5
    done

    docker logs "${name}" >"cache/${nim}-nim.populate.log" 2>&1 || true
    docker rm -f "${name}" >/dev/null 2>&1 || true

    local bytes
    bytes=$(du -sk "${dest}" | cut -f1)
    echo "${nim}: cache is $(( bytes / 1024 )) MiB, server_ready=${ready}"

    # A server that never answered may still have finished the download, which
    # is all we need - but an empty cache means it did not.
    if [ "${bytes}" -lt 1024 ]; then
        echo "${nim}: cache is essentially empty, see cache/${nim}-nim.populate.log" >&2
        return 1
    fi
}

TARGETS=("$@")
if [ "${#TARGETS[@]}" -eq 0 ]; then
    TARGETS=(rfdiffusion proteinmpnn openfold3)
fi

failed=0
for t in "${TARGETS[@]}"; do
    populate "${t}" || failed=1
done

echo
du -sh cache/*/ 2>/dev/null || true
exit "${failed}"
