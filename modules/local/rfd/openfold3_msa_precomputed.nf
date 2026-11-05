// Assembles each design's two alignments without searching anything.
//
// The target is the same cropped chain in every design, so its alignment is
// searched once (see params.msa_target_a3m) and reused. The binder is de novo
// and has no homologues, so its alignment is its own sequence - which is
// exactly what colabfold_search returned on every one of the 20 searches run
// on 2026-10-29, after 78 minutes each.
//
// openfold3_msa.py finalise still checks both A3Ms against the complex, so a
// target alignment that does not match this design's chain B fails the task
// rather than silently folding the wrong sequence.
process OPENFOLD3_MSA_PRECOMPUTED {
    tag "${design_id}"

    publishDir "${params.outdir}/rfd/openfold3", pattern: 'msas/*.a3m', mode: 'copy'

    input:
    tuple val(design_id), path(design_pdb)
    path target_a3m

    output:
    tuple val(design_id), path(design_pdb), path("msas/${design_id}.A.a3m"), path("msas/${design_id}.B.a3m"), emit: designs_with_msas
    path 'msas/*.a3m', emit: msas

    script:
    """
    set -euo pipefail
    mkdir -p msas

    openfold3_msa.py query-only \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --chain A \\
        --output "binder.a3m"

    openfold3_msa.py finalise \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --binder-msa "binder.a3m" \\
        --target-msa "${target_a3m}" \\
        --output-dir msas
    """
}
