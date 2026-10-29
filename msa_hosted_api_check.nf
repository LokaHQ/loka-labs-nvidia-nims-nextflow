#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: can we use NVIDIA's hosted msa-search
// endpoint instead of self-hosting the NIM? That would avoid both the
// nim/colabfold entitlement and the 1.4 TB database download.
nextflow.enable.dsl = 2

params.outdir = 'results'

process MSA_HOSTED_API_CHECK {
    queue 'nvidia-nims-cpu-small'
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:nf-binder-design-utils'
    cpus 1
    memory '2g'
    time 20.minutes

    publishDir "${params.outdir}/msa-hosted-api-check", mode: 'copy'

    output:
    path 'hosted_status.txt'
    path 'hosted_response.json'

    script:
    """
    set -uo pipefail

    export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \
        --secret-id "${params.ngc_api_key_secret}" \
        --region "${params.ngc_api_key_region}" \
        --query SecretString --output text)

    cat > payload.json <<'JSON'
{
  "sequence": "MVPSAGQLALFALGIVLAACQALENSTSPLSADPPVAAAVVSHFNDCPDSHTQFCFHGTCRFLVQEDKPACVCHSGYVGARCEHADLLA",
  "databases": ["all"],
  "e_value": 0.0001,
  "iterations": 1,
  "search_type": "colabfold",
  "output_alignment_formats": ["a3m"],
  "max_msa_sequences": 50
}
JSON

    start=\$(date +%s)
    code=\$(curl --silent --show-error \\
        --connect-timeout 15 --max-time 900 \\
        --output hosted_response.json --write-out '%{http_code}' \\
        --header "Authorization: Bearer \${NGC_API_KEY}" \\
        --header "Content-Type: application/json" \\
        --data @payload.json \\
        "https://health.api.nvidia.com/v1/biology/colabfold/msa-search/predict")
    elapsed=\$(( \$(date +%s) - start ))

    {
        echo "UTC: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "HTTP \${code}  health.api.nvidia.com/v1/biology/colabfold/msa-search/predict"
        echo "elapsed: \${elapsed}s"
        echo "response bytes: \$(wc -c < hosted_response.json)"
        echo "--- first 600 chars of response ---"
        head -c 600 hosted_response.json
    } > hosted_status.txt

    cat hosted_status.txt
    exit 0
    """
}

workflow {
    MSA_HOSTED_API_CHECK()
}
