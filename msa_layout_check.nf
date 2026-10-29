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
        \\( -name 'uniref30_2302_db' -o -name 'colabfold_envdb_202108_db' \\) -print

    echo
    echo "## what the snapshot directory actually contains"
    for d in "\${snapshots}"/*/; do
        echo "-- \${d}"
        ls -la "\${d}" | sed -n '1,6p'
        for sub in "\${d}"*/; do
            echo "---- \${sub}"
            ls -la "\${sub}" | sed -n '1,8p'
        done
    done

    echo
    echo "## find variants"
    echo "plain -name:      \$(find "\${snapshots}" -name 'uniref30_2302_db*' | wc -l)"
    echo "-L -type f:       \$(find -L "\${snapshots}" -type f -name 'uniref30_2302_db*' | wc -l)"
    echo "-L -type f md3:   \$(find -L "\${snapshots}" -maxdepth 3 -type f -name 'uniref30_2302_db*' | wc -l)"
    echo "-type l:          \$(find "\${snapshots}" -type l -name 'uniref30_2302_db*' | wc -l)"

    echo
    echo "## building a flat directory of symlinks"
    rm -rf "${params.msa_flat_dir}"
    mkdir -p "${params.msa_flat_dir}"
    for db in uniref30_2302 colabfold_envdb_202108; do
        src=\$(find "\${snapshots}" -maxdepth 2 -type d -name "\${db}" -print -quit)
        if [ -z "\${src}" ]; then
            echo "  \${db}: directory not found under snapshots"
            continue
        fi
        echo "  \${db}: linking from \${src}"
        for f in "\${src}"/*; do
            [ -e "\${f}" ] || continue
            name=\$(basename "\${f}")
            # Skip the NIM's precomputed .idx. It is built for GPU Server and
            # mmseqs tries to load it whole: "Estimated memory consumption: 81G
            # ... Computed index is too large. Avoid using the index." Without
            # it mmseqs reads the database directly - slower, far less memory.
            case "\${name}" in
                *.idx|*.idx.*) echo "    skipping \${name} (GPU index)"; continue;;
            esac
            ln -sf "\${f}" "${params.msa_flat_dir}/\${name}"
        done
    done
    echo "linked: \$(ls -1 "${params.msa_flat_dir}" | wc -l) file(s)"
    ls -1 "${params.msa_flat_dir}" | sed -n '1,8p'

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
