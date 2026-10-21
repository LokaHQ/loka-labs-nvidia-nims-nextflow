#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: asks NGC directly what it thinks of our key,
// so we see the HTTP status nimlib hides behind "Authentication Error".
// ipd/rfdiffusion is the control - that publisher works today.
nextflow.enable.dsl = 2

params.outdir = 'results'

process NGC_ENTITLEMENT_CHECK {
    queue 'nvidia-nims-cpu-small'
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:nf-binder-design-utils'
    cpus 1
    memory '2g'
    time 15.minutes

    publishDir "${params.outdir}/ngc-entitlement-check", mode: 'copy'

    output:
    path 'ngc_status.txt'
    path 'versions_*.json'

    script:
    """
    set -uo pipefail

    export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \
        --secret-id "${params.ngc_api_key_secret}" \
        --region "${params.ngc_api_key_region}" \
        --query SecretString --output text)

    if [ -z "\${NGC_API_KEY:-}" ]; then
        echo "NGC_API_KEY is unavailable" >&2
        exit 1
    fi

    echo "UTC: \$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ngc_status.txt

    # The versions nimlib actually asks for, including the two big databases.
    for v in colabfold_envdb_202108-m18v1 uniref30_2302-m18v1 pdb100_230517-m18v1; do
        code=\$(curl --silent --show-error --connect-timeout 10 --max-time 60 \\
            --output /dev/null --write-out '%{http_code}' \\
            --header "Authorization: Bearer \${NGC_API_KEY}" \\
            "https://api.ngc.nvidia.com/v2/org/nim/team/colabfold/models/msa-search/\${v}/files")
        echo "HTTP \${code}  colabfold/msa-search/\${v}/files" >> ngc_status.txt
    done

    # Version lists first - the files endpoint needs an exact version string.
    for team_model in "colabfold/msa-search" "ipd/rfdiffusion"; do
        team=\${team_model%%/*}
        model=\${team_model##*/}
        out="versions_\${team}_\${model}.json"
        code=\$(curl --silent --show-error --connect-timeout 10 --max-time 60 \\
            --output "\$out" --write-out '%{http_code}' \\
            --header "Authorization: Bearer \${NGC_API_KEY}" \\
            "https://api.ngc.nvidia.com/v2/org/nim/team/\${team}/models/\${model}/versions")
        echo "HTTP \${code}  \${team}/\${model}/versions" >> ngc_status.txt
        echo "  versions seen: \$(grep -o '\"versionId\":\"[^\"]*\"' "\$out" 2>/dev/null | head -8 | tr '\\n' ' ')" >> ngc_status.txt
    done

    # Then the files endpoint for each version we found.
    for team_model in "colabfold/msa-search" "ipd/rfdiffusion"; do
        team=\${team_model%%/*}
        model=\${team_model##*/}
        out="versions_\${team}_\${model}.json"
        for v in \$(grep -o '\"versionId\":\"[^\"]*\"' "\$out" 2>/dev/null | sed 's/.*:\"//;s/\"//' | head -3); do
            code=\$(curl --silent --show-error --connect-timeout 10 --max-time 60 \\
                --output /dev/null --write-out '%{http_code}' \\
                --header "Authorization: Bearer \${NGC_API_KEY}" \\
                "https://api.ngc.nvidia.com/v2/org/nim/team/\${team}/models/\${model}/\${v}/files")
            echo "HTTP \${code}  \${team}/\${model}/\${v}/files" >> ngc_status.txt
        done
    done

    cat ngc_status.txt
    """
}

workflow {
    NGC_ENTITLEMENT_CHECK()
}
