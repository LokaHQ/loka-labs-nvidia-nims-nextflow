// Co-folds binder+target sequences (extracted from the ProteinMPNN-threaded
// PDB) with OpenFold3, replacing AF2 initial-guess. See bin/openfold3_predict.py.
process OPENFOLD3 {
    container "520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:openfold3-v0.5-pixi"

    publishDir "${params.outdir}/rfd/openfold3", pattern: 'pdbs/*.pdb', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3", pattern: 'scores/*.tsv', mode: 'copy'

    input:
    path 'input/*'
    // Per-chain alignments named <query_id>.{A,B}.a3m. Pass an empty list to let
    // OpenFold3 run its own MSA search instead.
    path 'msas/*'

    output:
    tuple path('pdbs/*.pdb'), path('openfold3_scores.tsv'), emit: pdbs_with_scores
    path 'pdbs/*.pdb', emit: pdbs
    path 'scores/*.tsv', emit: scores

    script:
    """
    set -euo pipefail

    setup_openfold --non-interactive

    cat > runner.yml <<'YAML'
output_writer_settings:
  structure_format: pdb
YAML

    msa_arg=""
    if ls msas/*.a3m >/dev/null 2>&1; then
        msa_arg="msas/"
    fi

    openfold3_predict.py input/ pdbs/ scores/ runner.yml \${msa_arg}
    openfold3_combine_scores.py scores/ -o openfold3_scores.tsv
    """
}
