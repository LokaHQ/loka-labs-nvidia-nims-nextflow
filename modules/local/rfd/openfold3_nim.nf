// Uses openfold3-nim with the PAE response patch (see assets/openfold3_nim).
// Read sequences and independent ColabFold MSAs for the threaded complex,
// preserving the target crop without pairing binder and target alignments.
// OpenFold3 folds from sequence; the coordinates are not an initial guess.
process OPENFOLD3_NIM {
    tag "${design_id}"
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'pdbs/*.pdb', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'scores/*.tsv', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'raw/*.json', mode: 'copy'

    input:
    tuple val(design_id), path(design_pdb), path(binder_msa), path(target_msa)

    output:
    path 'pdbs/*.pdb', emit: pdbs
    path 'scores/*.tsv', emit: scores
    tuple path('pdbs/*.pdb'), path('scores/*.tsv'), emit: pdbs_with_scores
    path 'raw/*.json', emit: raw
    tuple val(design_id), path('pdbs/*.pdb'), path('scores/*.tsv'), path('raw/*.json'), emit: predictions

    script:
    """
    set -euo pipefail
    mkdir -p pdbs scores raw

    # Kill the NIM server on exit so the container doesn't hang.
    SELF_PID=\$\$
    trap '
        code=\$?
        for pid in \$(pgrep -g "\$SELF_PID" 2>/dev/null); do
            if [ "\$pid" != "\$SELF_PID" ]; then
                kill -9 "\$pid" 2>/dev/null || true
            fi
        done
        pkill -9 -f start_server 2>/dev/null || true
        exit "\$code"
    ' EXIT

    if [ -n "${params.ngc_api_key_secret ?: ''}" ]; then
        export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \
            --secret-id "${params.ngc_api_key_secret ?: ''}" \
            --region "${params.ngc_api_key_region}" \
            --query SecretString \
            --output text)
    fi
    if [ -z "\${NGC_API_KEY:-}" ]; then
        echo "NGC_API_KEY is unavailable" >&2
        exit 1
    fi

    /opt/nim/start_server.sh > nim_server.log 2>&1 &

    # Longer budget than the RFdiffusion/ProteinMPNN NIMs - OpenFold3 pulls
    # ~15GB of model parameters into its cache on a cold start.
    for i in \$(seq 1 120); do
        if curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
            echo "NIM server ready after \${i} check(s)"
            break
        fi
        echo "Waiting for NIM server to be ready (\${i}/120)..."
        sleep 10
    done

    if ! curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
        echo "NIM server never became ready. Last 100 lines of nim_server.log:" >&2
        tail -n 100 nim_server.log >&2
        exit 1
    fi

    openfold3_nim_call.py \\
        --input-pdb "${design_pdb}" \\
        --binder-msa "${binder_msa}" \\
        --target-msa "${target_msa}" \\
        --design-id "${design_id}" \\
        --output-dir .
    """
}
