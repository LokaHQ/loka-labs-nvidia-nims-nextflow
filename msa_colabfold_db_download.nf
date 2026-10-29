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
    # tee rather than redirect: a plain redirect sends everything to a file
    # Nextflow only publishes on success, so a failure leaves .command.err
    # empty and the reason is lost with the task directory.
    exec > >(tee colabfold_db_report.txt) 2>&1

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
        # Only ask to resume when there is something to resume. These URLs 302
        # to another host, and curl aborts a range request it cannot satisfy
        # across the redirect with "server doesn't seem to support byte
        # ranges" - six seconds in, which looks nothing like a network fault.
        resume=""
        [ -f "\$name" ] && resume="-C -"
        curl -fL --retry 5 --retry-delay 10 \$resume -o "\$name" "\$url"
        echo "## unpacking \$name"
        tar xzf "\$name"
        rm -f "\$name"
        touch "\$marker"
    done

    # The tarballs hold TSVs, not searchable databases. setup_databases.sh
    # converts them with tsv2exprofiledb and that step was missing here, so an
    # earlier run reported success having produced nothing colabfold_search
    # can read.
    #
    # No `mmseqs createindex`: the index is exactly what pushed the search to
    # an estimated 81 GB against this queue's 27 GB.
    for db in uniref30_2302 colabfold_envdb_202108; do
        if [ -e "\${db}_db" ]; then
            echo "## \${db}_db already built, skipping"
            continue
        fi
        # A conversion killed partway leaves _db.0.._db.N behind without the
        # bare _db file this check looks for. mmseqs will not overwrite them,
        # so clear them before retrying.
        if ls "\${db}_db".* >/dev/null 2>&1; then
            echo "## clearing a partial \${db}_db from an interrupted run"
            rm -f "\${db}_db".* "\${db}_db"_*
        fi
        echo "## building \${db}_db from TSVs"
        mmseqs tsv2exprofiledb "\${db}" "\${db}_db"
        # Reclaim the TSVs immediately. Both database sets plus the NIM's own
        # 1.2 TB do not fit on a 2.4 TB filesystem otherwise.
        echo "## removing \${db} TSVs"
        rm -f "\${db}".tsv "\${db}"_*.tsv
        df -h "${params.msa_mount}" | tail -1
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

    """
}

workflow {
    DOWNLOAD_COLABFOLD_DATABASES()
}
