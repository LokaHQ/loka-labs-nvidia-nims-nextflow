#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: standalone smoke test for the MSA Search
// NIM (colabfold/msa-search), evaluating it in isolation before any decision
// to wire it into rfd_nim.nf.
nextflow.enable.dsl = 2

params.outdir = 'results'

process MSA_NIM_SMOKE_TEST {
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:msa-search'
    accelerator = 1
    cpus = 8
    memory = '64g'
    time = 1.hour

    publishDir "${params.outdir}/msa-nim-smoke-test", mode: 'copy'

    output:
    path 'msa_nim_response.json'
    path 'nim_server.log'

    script:
    """
    set -euo pipefail

    SELF_PID=\$\$
    trap '
        code=\$?
        for pid in \$(pgrep -g "\$SELF_PID" 2>/dev/null); do
            if [ "\$pid" != "\$SELF_PID" ]; then
                kill -9 "\$pid" 2>/dev/null || true
            fi
        done
        exit "\$code"
    ' EXIT

    /opt/nim/start_server.sh > nim_server.log 2>&1 &

    for i in \$(seq 1 60); do
        if curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
            echo "NIM server ready after \${i} check(s)"
            break
        fi
        echo "Waiting for NIM server to be ready (\${i}/60)..."
        sleep 10
    done

    if ! curl -sf http://localhost:8000/v1/health/ready > /dev/null 2>&1; then
        echo "NIM server never became ready. Last 100 lines of nim_server.log:" >&2
        tail -n 100 nim_server.log >&2
        exit 1
    fi

    msa_search_nim_smoke_test.py
    """
}

workflow {
    MSA_NIM_SMOKE_TEST()
}
