// NIM-arm counterpart to OPENFOLD3_MSA_LOCAL: runs the MSA Search NIM against
// the same databases on /fsx that colabfold_search reads, so the MSA step
// compares two implementations on our own hardware rather than one of them
// against a public API.
//
// Starts its own server per task, as RFDIFFUSION_NIM and OPENFOLD3_NIM do. That
// is the honest shape for the comparison - both arms pay their own setup inside
// the timed task - but it does mean a server start per design rather than once
// per run. GPU Server holds the databases in memory, so this needs two 48 GB
// cards and lands on gpu-highmem, not gpu-standard.
//
// Mirrors OPENFOLD3_MSA's prepare/search/finalise shape so the two arms carry
// the same non-search overhead.
process OPENFOLD3_MSA_NIM {
    tag "${design_id}"
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'msas/*.a3m', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'queries/*.fasta', mode: 'copy'

    input:
    tuple val(design_id), path(design_pdb)

    output:
    tuple val(design_id), path(design_pdb), path("msas/${design_id}.A.a3m"), path("msas/${design_id}.B.a3m"), emit: designs_with_msas
    path 'msas/*.a3m', emit: msas
    path 'queries/*.fasta', emit: queries
    path 'nim_server.log', emit: server_log

    script:
    """
    set -euo pipefail
    mkdir -p queries search msas

    if [ ! -d "${params.msa_db_dir}" ]; then
        echo "MSA databases not found at ${params.msa_db_dir}" >&2
        exit 1
    fi

    # Kill the server on exit so the task cannot hang holding a GPU instance.
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

    # Point the NIM at the pre-loaded databases so it finds them present and
    # does not try to pull ~1.2 TB from NGC on every task.
    export NIM_CACHE_PATH="${params.msa_db_dir}"

    if [ -n "${params.ngc_api_key_secret ?: ''}" ]; then
        export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \\
            --secret-id "${params.ngc_api_key_secret ?: ''}" \\
            --region "${params.ngc_api_key_region}" \\
            --query SecretString \\
            --output text)
    fi
    if [ -z "\${NGC_API_KEY:-}" ]; then
        echo "NGC_API_KEY is unavailable" >&2
        exit 1
    fi

    /opt/nim/start_server.sh > nim_server.log 2>&1 &

    for i in \$(seq 1 ${params.msa_nim_ready_checks}); do
        if curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
            echo "NIM server ready after \${i} check(s)"
            break
        fi
        sleep 10
    done

    if ! curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
        echo "NIM server never became ready. Last 100 lines:" >&2
        tail -n 100 nim_server.log >&2
        exit 1
    fi

    openfold3_msa.py prepare \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --output "queries/${design_id}.fasta"

    msa_search_nim.py \\
        --fasta "queries/${design_id}.fasta" \\
        --output search/ \\
        --host "http://localhost:8000" \\
        --databases "${params.msa_nim_databases}" \\
        --max-msa-sequences ${params.msa_nim_max_sequences}

    openfold3_msa.py finalise \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --binder-msa "search/${design_id}_0.a3m" \\
        --target-msa "search/${design_id}_1.a3m" \\
        --output-dir msas
    """
}
