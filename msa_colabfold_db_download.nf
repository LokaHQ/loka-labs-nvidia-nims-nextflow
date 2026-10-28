#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: fetches ColabFold's own copy of the MSA
// databases, for use only if the baseline pipeline cannot read the ones the
// MSA Search NIM downloaded.
//
// The NIM's copy comes from the same ColabFold tarballs, but it post-processes
// them for GPU Server (a .GPU_READY marker sits beside each database). If that
// processing makes them unreadable by stock mmseqs, the two implementations
// cannot share one copy and each needs its own - which is itself a finding
// about what self-hosting the NIM actually costs.
//
// Deliberately does NOT run `mmseqs createindex`. The index is what pushed the
// search to an estimated 81 GB against the 27 GB this queue provides; without
// it the same search estimates 23 GB. Slower, but it fits.
nextflow.enable.dsl = 2

params.colabfold_db_dir = '/fsx/colabfold-db'
params.msa_mount = '/fsx'
params.outdir = 'results'

process DOWNLOAD_COLABFOLD_DATABASES {
    publishDir "${params.outdir}/msa-db", mode: 'copy'

    output:
    path 'colabfold_db_report.txt'

    script:
    """
    set -eu
    exec 3>&1 1>colabfold_db_report.txt 2>&1

    if [ ! -d "${params.msa_mount}" ]; then
        echo "FSx not mounted at ${params.msa_mount}" >&2
        exit 1
    fi
    mkdir -p "${params.colabfold_db_dir}"
    cd "${params.colabfold_db_dir}"

    echo "## free space before"
    df -h "${params.msa_mount}" | tail -1

    started=\$(date +%s)
    for url in \\
        https://wwwuser.gwdg.de/~compbiol/colabfold/uniref30_2302.tar.gz \\
        https://wwwuser.gwdg.de/~compbiol/colabfold/colabfold_envdb_202108.tar.gz
    do
        name=\$(basename "\$url")
        marker=".\${name}.done"
        if [ -f "\$marker" ]; then
            echo "## \$name already unpacked, skipping"
            continue
        fi
        echo "## fetching \$name"
        # -C - resumes a partial download rather than restarting ~100 GB.
        curl -fL -C - -o "\$name" "\$url"
        echo "## unpacking \$name"
        tar xzf "\$name"
        rm -f "\$name"
        touch "\$marker"
    done
    finished=\$(date +%s)

    echo
    echo "## elapsed_seconds: \$(( finished - started ))"
    echo "## free space after"
    df -h "${params.msa_mount}" | tail -1
    echo
    echo "## what we have"
    ls -1 | sed -n '1,40p'
    echo
    echo "## the files colabfold_search looks for"
    for db in uniref30_2302_db colabfold_envdb_202108_db; do
        printf '%s: ' "\$db"
        if [ -e "\$db" ]; then echo "present"; else echo "MISSING"; fi
    done

    chown -R 1000:1000 "${params.colabfold_db_dir}" || true
    chmod -R a+rX "${params.colabfold_db_dir}" || true

    cat colabfold_db_report.txt >&3
    """
}

workflow {
    DOWNLOAD_COLABFOLD_DATABASES()
}
