#!/usr/bin/env nextflow
// Ad-hoc throwaway: can colabfold_search read the databases the MSA NIM
// downloaded, or does the baseline pipeline need its own ~0.8 TB copy?
//
// The NIM lays them out one directory deep per database:
//   /fsx/msa/ngc/hub/models--nim--colabfold--msa-search/snapshots/
//     uniref30_2302-m18v1/uniref30_2302/uniref30_2302_db.*
//     colabfold_envdb_202108-m18v1/colabfold_envdb_202108/colabfold_envdb_202108_db.*
//
// colabfold_search wants one flat directory containing both. The basenames
// already match what it expects, so symlinks should be enough - this proves it
// on a real two-chain query before the benchmark depends on it.
nextflow.enable.dsl = 2

params.msa_db_dir = '/fsx/msa'
params.msa_flat_dir = '/fsx/msa-flat'
params.outdir = 'results'

process CHECK_MSA_LAYOUT {
    publishDir "${params.outdir}/msa-db", mode: 'copy'

    output:
    path 'layout_check.txt'
    path 'search.log', optional: true
    path 'search_out/**', optional: true

    script:
    """
    # No pipefail: `head`/`sed` closing a pipe early would otherwise kill the
    # script with SIGPIPE before it reports anything.
    set -eu
    exec 3>&1 1>layout_check.txt 2>&1

    snapshots="${params.msa_db_dir}/ngc/hub/models--nim--colabfold--msa-search/snapshots"
    echo "## database files the NIM downloaded"
    find "\${snapshots}" -maxdepth 3 \\
        \( -name 'uniref30_2302_db' -o -name 'colabfold_envdb_202108_db' \) -print

    echo
    echo "## building a flat directory of symlinks"
    mkdir -p "${params.msa_flat_dir}"
    find "\${snapshots}" -maxdepth 3 -type f \\
        \\( -name 'uniref30_2302_db*' -o -name 'colabfold_envdb_202108_db*' \\) \\
        -exec ln -sf {} "${params.msa_flat_dir}/" \\;
    echo "linked: \$(ls "${params.msa_flat_dir}" | wc -l) file(s)"

    echo
    echo "## a two-chain query, as the pipeline would send"
    mkdir -p search_out
    cat > query.fasta <<'FASTA'
>probe.A binder
SKQEELAKAKEELAKRLEELAKKAEEMLKKAQELLKKAEELLKKAS
>probe.B target
FTVTVPKDLYVVEYGSNMTIECKFPVEKQLDLAALIVYWEMEDKNIIQFVHGEEDLKVQHSSYRQRARLLKDQLSLGNAALQITDVKLQDAGVYRCMISYGGADYKRITVKVNA
FASTA

    if colabfold_search --db-load-mode 2 --threads ${task.cpus} \\
            query.fasta "${params.msa_flat_dir}" search_out/ >search.log 2>&1; then
        echo "RESULT: colabfold_search READ the NIM layout"
        tail -15 search.log
        find search_out -name '*.a3m' -print
        for f in \$(find search_out -name '*.a3m'); do
            echo "\${f}: \$(grep -c '^>' "\${f}") sequence(s)"
        done
    else
        echo "RESULT: colabfold_search FAILED - the baseline may need its own copy"
        tail -30 search.log
    fi

    cat layout_check.txt >&3
    """
}

workflow {
    CHECK_MSA_LAYOUT()
}
