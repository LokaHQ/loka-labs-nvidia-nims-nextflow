#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: control for the MSA NIM auth failure.
// Starts the RFdiffusion NIM server the same way rfdiffusion_nim.nf does and
// reports only whether nimlib's model download authenticates. If this fails
// too, the current NGC key is bad for nimlib generally, not just msa-search.
nextflow.enable.dsl = 2

params.outdir = 'results'

process RFD_NIM_AUTH_CONTROL {
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:rfdiffusion-nim'
    accelerator 1
    cpus 2
    memory '16g'
    time 30.minutes

    publishDir "${params.outdir}/rfd-nim-auth-control", mode: 'copy'

    output:
    path 'result.txt'

    script:
    """
    export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \
        --secret-id "${params.ngc_api_key_secret}" \
        --region "${params.ngc_api_key_region}" \
        --query SecretString --output text)

    # Empty cache forces nimlib down the NGC download path, which the image's
    # baked-in weights otherwise skip entirely.
    mkdir -p /tmp/empty_nim_cache
    export NIM_CACHE_PATH=/tmp/empty_nim_cache

    /opt/nim/start_server.sh > nim_server.log 2>&1 &

    ready=no
    for i in \$(seq 1 60); do
        if curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
            ready=yes
            break
        fi
        if grep -q "Authentication Error" nim_server.log 2>/dev/null; then
            break
        fi
        sleep 10
    done

    {
        echo "UTC: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "server ready: \$ready"
        echo "auth error in log: \$(grep -c 'Authentication Error' nim_server.log 2>/dev/null || echo 0)"
        echo "download attempted: \$(grep -c 'fetching filemap\\|Downloading manifest' nim_server.log 2>/dev/null || echo 0)"
        echo "--- NGC calls ---"
        grep -E 'fetching filemap|Downloading manifest|api.ngc' nim_server.log 2>/dev/null | head -5
        echo "--- last 40 lines ---"
        tail -n 40 nim_server.log 2>/dev/null
    } > result.txt

    cat result.txt
    pkill -9 -f start_server 2>/dev/null || true
    exit 0
    """
}

workflow {
    RFD_NIM_AUTH_CONTROL()
}
