// Baseline-arm counterpart to OPENFOLD3_MSA: searches binder A and target B
// against locally-hosted databases with colabfold_search, so the NIM-vs-no-NIM
// MSA comparison runs on hardware we control rather than a public API.
//
// Unlike modules/local/common/mmseqs_colabfoldsearch.nf the databases are NOT
// staged - params.msa_db_dir is a path inside the container, backed by the FSx
// mount, because the database set is ~1.4 TB.
//
// Mirrors OPENFOLD3_MSA's prepare/search/finalise structure so both arms carry
// the same non-search overhead inside the timed task.
process OPENFOLD3_MSA_LOCAL {
    tag "${design_id}"
    publishDir "${params.outdir}/rfd/openfold3", pattern: 'msas/*.a3m', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3", pattern: 'queries/*.fasta', mode: 'copy'

    input:
    tuple val(design_id), path(design_pdb)

    output:
    tuple val(design_id), path(design_pdb), path("msas/${design_id}.A.a3m"), path("msas/${design_id}.B.a3m"), emit: designs_with_msas
    path 'msas/*.a3m', emit: msas
    path 'queries/*.fasta', emit: queries

    script:
    def search_args = params.msa_local_search_args ?: ''
    """
    set -euo pipefail
    mkdir -p queries search msas

    if [ ! -d "${params.msa_db_dir}" ]; then
        echo "MSA database directory not found: ${params.msa_db_dir}" >&2
        exit 1
    fi

    openfold3_msa.py prepare \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --output "queries/${design_id}.fasta"

    colabfold_search ${search_args} \\
        --threads ${task.cpus} \\
        "queries/${design_id}.fasta" \\
        "${params.msa_db_dir}" \\
        search/

    # colabfold_search names unpacked A3Ms from the query header or its index,
    # depending on version. Accept either and fail loudly rather than guessing.
    for chain_index in 0 1; do
        chain_id=\$([ "\${chain_index}" = "0" ] && echo A || echo B)
        target="search/${design_id}_\${chain_index}.a3m"
        for candidate in \\
            "search/${design_id}.\${chain_id}.a3m" \\
            "search/\${chain_index}.a3m" \\
            "search/${design_id}_\${chain_index}.a3m"; do
            if [ -f "\${candidate}" ]; then
                [ "\${candidate}" = "\${target}" ] || mv "\${candidate}" "\${target}"
                break
            fi
        done
        if [ ! -f "\${target}" ]; then
            echo "colabfold_search produced no alignment for chain \${chain_id}" >&2
            ls -la search/ >&2
            exit 1
        fi
    done

    openfold3_msa.py finalise \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --binder-msa "search/${design_id}_0.a3m" \\
        --target-msa "search/${design_id}_1.a3m" \\
        --output-dir msas
    """
}
