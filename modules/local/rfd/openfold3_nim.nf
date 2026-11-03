// Uses openfold3-nim with the PAE response patch (see assets/openfold3_nim).
// Read sequences and independent ColabFold MSAs for the threaded complex,
// preserving the target crop without pairing binder and target alignments.
// OpenFold3 folds from sequence; the coordinates are not an initial guess.
process OPENFOLD3_NIM {
    tag "${design_ids.size()} design(s)"
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'pdbs/*.pdb', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'scores/*.tsv', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'raw/*.json', mode: 'copy'

    input:
    // Lists, one entry per design in the batch. The NIM server boot is ~105 s
    // against ~17 s of inference, so serving a batch from one server is the
    // difference between measuring startup and measuring the model.
    tuple val(design_ids), path(design_pdbs), path(binder_msas), path(target_msas)

    output:
    path 'pdbs/*.pdb', emit: pdbs
    path 'scores/*.tsv', emit: scores
    tuple path('pdbs/*.pdb'), path('scores/*.tsv'), emit: pdbs_with_scores
    path 'raw/*.json', emit: raw
    tuple val(design_ids), path('pdbs/*.pdb'), path('scores/*.tsv'), path('raw/*.json'), emit: predictions

    script:
    def manifest_rows = [design_ids, design_pdbs, binder_msas, target_msas]
        .transpose()
        .collect { did, pdb, bmsa, tmsa -> "${did}\t${pdb}\t${bmsa}\t${tmsa}" }
        .join('\n')
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

    cat > batch_manifest.tsv <<'MANIFEST'
${manifest_rows}
MANIFEST

    # One server, N requests. Each call appends to pdbs/ scores/ raw/.
    while IFS=\$'\\t' read -r did pdb bmsa tmsa; do
        [ -n "\${did}" ] || continue
        echo "=== folding \${did} ==="
        openfold3_nim_call.py \\
            --input-pdb "\${pdb}" \\
            --binder-msa "\${bmsa}" \\
            --target-msa "\${tmsa}" \\
            --design-id "\${did}" \\
            --output-dir .
    done < batch_manifest.tsv
    """
}
