#!/usr/bin/env nextflow
// Ad-hoc throwaway: one short task that reports what the database loader
// actually has to work with, instead of discovering it one long failed
// download at a time. Reports free space on every mount, where the NIM's
// downloader stages files, and whether the FSx directory is writable by the
// uid the NIM images run as.
nextflow.enable.dsl = 2

params.msa_mount = '/fsx'
params.msa_db_dir = '/fsx/msa'
params.outdir = 'results'

process PROBE_MSA_ENV {
    publishDir "${params.outdir}/msa-db", mode: 'copy'

    output:
    path 'probe.txt'

    script:
    """
    set -euo pipefail
    {
        echo "## whoami"
        id

        echo
        echo "## disk space"
        df -h

        echo
        echo "## is ${params.msa_mount} present and writable"
        ls -ld "${params.msa_mount}" || echo "MISSING"
        touch "${params.msa_mount}/.probe-\$\$" 2>&1 && echo "writable" && rm -f "${params.msa_mount}/.probe-\$\$" || echo "NOT writable"

        echo
        echo "## temp dirs the downloader might stage through"
        for d in /tmp \${TMPDIR:-/tmp} "\$PWD"; do
            printf '%s -> ' "\$d"
            df -h "\$d" 2>/dev/null | tail -1 || echo "?"
        done

        echo
        echo "## relevant env"
        env | grep -iE 'TMP|CACHE|HF_|NGC|NIM_' | sort || true

        echo
        echo "## already on the filesystem"
        du -sh "${params.msa_db_dir}" 2>/dev/null || echo "nothing at ${params.msa_db_dir}"
        find "${params.msa_mount}" -maxdepth 3 2>/dev/null | head -30
    } > probe.txt 2>&1

    cat probe.txt
    """
}

workflow {
    PROBE_MSA_ENV()
}
