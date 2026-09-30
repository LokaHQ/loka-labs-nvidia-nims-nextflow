process OPENFOLD3_SCORE_FILTER {
    tag "${design_id}"
    container 'ghcr.io/australian-protein-design-initiative/containers/nf-binder-design-utils:0.1.6'
    publishDir "${params.outdir}/rfd/openfold3_nim/filtered", mode: 'copy'

    input:
    tuple val(design_id), path(pdb), path(scores)
    val filters

    output:
    tuple val(design_id), path('accepted/*.pdb'), emit: accepted, optional: true
    tuple val(design_id), path('rejected/*.pdb'), emit: rejected, optional: true
    tuple val(design_id), path("${design_id}.filtered.tsv"), emit: scores

    script:
    def quoted_filters = "'" + (filters ?: '').toString().replace("'", "'\"'\"'") + "'"
    """
    set -euo pipefail
    filter_openfold3_scores.py \\
        --scores "${scores}" \\
        --pdb "${pdb}" \\
        --filters ${quoted_filters} \\
        --collect-in . \\
        --output "${design_id}.filtered.tsv"
    """
}
