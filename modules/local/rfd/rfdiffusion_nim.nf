// Uses rfdiffusion-nim with its ENTRYPOINT cleared for AWS Batch.
process RFDIFFUSION_NIM {
    publishDir "${params.outdir}/rfd/rfdiffusion", pattern: 'pdbs/*.pdb', mode: 'copy'

    input:
    path input_pdb
    val contigs
    val hotspot_res
    // Lists, one entry per design in the batch. Each design is an independent
    // request carrying its own RFD_RANDOM_SEED, so batching cannot change which
    // seed a design gets - unlike the upstream path, where the seed rides in as
    // design_startnum and num_designs would shift it.
    tuple val(design_indices), val(random_seeds)
    val unique_id

    output:
    path 'pdbs/*.pdb', emit: pdbs

    script:
    def batch_rows = [design_indices, random_seeds]
        .transpose()
        .collect { idx, seed -> "${idx}\t${seed != false ? (seed as int) : ''}" }
        .join('\n')
    """
    set -euo pipefail
    mkdir -p pdbs

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

    export RFD_INPUT_PDB="${input_pdb}"
    export RFD_CONTIGS="${contigs}"
    export RFD_HOTSPOT_RES="${hotspot_res}"
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

    for i in \$(seq 1 60); do
        if curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
            echo "NIM server ready after \${i} check(s)"
            break
        fi
        echo "Waiting for NIM server to be ready (\${i}/60)..."
        sleep 5
    done
    curl -sf http://localhost:8000/v1/health/ready

    cat > batch_designs.tsv <<'DESIGNS'
${batch_rows}
DESIGNS

    # One server, N requests. The ~75 s boot is paid once for the whole batch.
    while IFS=\$'\\t' read -r idx seed; do
        [ -n "\${idx}" ] || continue
        export RFD_OUTPUT_PDB="pdbs/design_ppi_${unique_id}_\${idx}.pdb"
        if [ -n "\${seed}" ]; then
            export RFD_RANDOM_SEED="\${seed}"
        else
            unset RFD_RANDOM_SEED || true
        fi
        echo "=== design \${idx} (seed \${seed:-none}) ==="
        rfdiffusion_nim_call.py
    done < batch_designs.tsv
    """
}
