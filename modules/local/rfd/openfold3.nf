// Co-folds binder+target sequences (extracted from the ProteinMPNN-threaded
// PDB) with OpenFold3, replacing AF2 initial-guess. See bin/openfold3_predict.py.
process OPENFOLD3 {
    container "520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:openfold3-v0.5-pixi"

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
    set -euo pipefail

    setup_openfold --non-interactive

    cat > runner.yml <<'YAML'
output_writer_settings:
  structure_format: pdb
YAML

    openfold3_predict.py input/ pdbs/ scores/ runner.yml
    openfold3_combine_scores.py scores/ -o openfold3_scores.tsv
    """
}
