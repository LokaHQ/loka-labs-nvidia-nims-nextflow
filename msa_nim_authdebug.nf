#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: starts the MSA NIM only to capture the full
// nim_server.log. The smoke test loses it because the task fails before outputs
// are staged, so the real HTTP status behind nimlib's "Authentication Error"
// never reaches us. This one always exits 0 so the log is published.
nextflow.enable.dsl = 2

params.outdir = 'results'

process MSA_NIM_AUTHDEBUG {
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:msa-search'
    accelerator 1
    cpus 8
    memory '64g'
    time 30.minutes

    publishDir "${params.outdir}/msa-nim-authdebug", mode: 'copy'

    output:
    path 'nim_server.log'
    path 'env_dump.txt'

    script:
    """
    set -uo pipefail

    export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \
        --secret-id "${params.ngc_api_key_secret}" \
        --region "${params.ngc_api_key_region}" \
        --query SecretString --output text)

    {
        echo "UTC: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "key length: \${#NGC_API_KEY}"
        echo "key prefix: \${NGC_API_KEY:0:6}"
        echo "NIM_CACHE_PATH: \${NIM_CACHE_PATH:-unset}"
        echo "cache writable: \$( [ -w "\${NIM_CACHE_PATH:-/opt/nim/.cache}" ] && echo yes || echo no )"
        df -h "\${NIM_CACHE_PATH:-/opt/nim/.cache}" 2>&1 | tail -2
    } > env_dump.txt

    # Ask every layer for maximum verbosity; unsupported names are harmless.
    export NIM_LOG_LEVEL=DEBUG
    export NIM_SDK_LOG_LEVEL=DEBUG
    export NGC_CLI_DEBUG=1
    export PYTHONUNBUFFERED=1

    timeout 600 /opt/nim/start_server.sh > nim_server.log 2>&1 || true

    echo "--- exit captured, log size: \$(wc -c < nim_server.log) bytes" >> env_dump.txt
    cat env_dump.txt
    tail -n 60 nim_server.log
    """
}

workflow {
    MSA_NIM_AUTHDEBUG()
}
