// Scaffold - CLI flags/output paths not yet verified against a real built
// container (aqlaboratory/openfold-3). Confirm once that image exists.
process OPENFOLD3 {
    container 'ghcr.io/australian-protein-design-initiative/containers/openfold3:latest'

    publishDir "${params.outdir}/rfd/openfold3", pattern: 'pdbs/*.pdb', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3", pattern: 'scores/*.tsv', mode: 'copy'

    input:
    path 'input/*'

    output:
    tuple path('pdbs/*.pdb'), path('openfold3_scores.tsv'), emit: pdbs_with_scores
    path 'pdbs/*.pdb', emit: pdbs
    path 'scores/*.tsv', emit: scores

    script:
    """
    mkdir -p pdbs scores

    PREFIX=\$(ls input/*.pdb | head -n1 | xargs basename | sed 's/\\.pdb\$//')

    # TODO: real openfold3 CLI invocation once container exists. Co-folds
    # target + binder sequence together (see workflow header for why).
    openfold3_predict.py \
        --input-dir input/ \
        --output-dir pdbs/ \
        --scores-out scores/\${PREFIX}.scores.tsv

    openfold3_combine_scores.py scores/ -o openfold3_scores.tsv
    """
}
