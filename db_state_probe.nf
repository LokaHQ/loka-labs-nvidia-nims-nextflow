nextflow.enable.dsl = 2
params.outdir = 'results'
process DB_STATE {
    publishDir "${params.outdir}/msa-db", mode: 'copy'
    output:
    path 'db_state.txt'
    script:
    """
    set -eu
    exec > >(tee db_state.txt) 2>&1
    echo "## space"
    df -h /fsx | tail -1
    echo
    echo "## colabfold-db contents"
    ls -1 /fsx/colabfold-db 2>/dev/null | head -40
    echo
    echo "## markers"
    ls -1a /fsx/colabfold-db | grep '^\\.' | head
    echo
    echo "## what colabfold_search needs"
    for f in uniref30_2302_db colabfold_envdb_202108_db; do
        printf '%s: ' "\$f"
        [ -e "/fsx/colabfold-db/\$f" ] && echo present || echo MISSING
    done
    echo
    echo "## TSVs still present"
    ls -1 /fsx/colabfold-db/*.tsv 2>/dev/null | head || echo none
    echo
    echo "## sizes"
    du -sh /fsx/colabfold-db /fsx/msa 2>/dev/null
    """
}
workflow { DB_STATE() }
