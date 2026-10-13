// Search binder A and target B together through the unpaired ColabFold API.
// The process is kept separate from GPU inference so its results can be resumed.
process OPENFOLD3_MSA {
    tag "${design_id}"
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'msas/*.a3m', mode: 'copy'
    publishDir "${params.outdir}/rfd/openfold3_nim", pattern: 'queries/*.fasta', mode: 'copy'

    input:
    tuple val(design_id), path(design_pdb)

    output:
    tuple val(design_id), path(design_pdb), path("msas/${design_id}.A.a3m"), path("msas/${design_id}.B.a3m"), emit: designs_with_msas
    path 'msas/*.a3m', emit: msas
    path 'queries/*.fasta', emit: queries

    script:
    """
    set -euo pipefail
    mkdir -p queries search msas

    openfold3_msa.py prepare \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --output "queries/${design_id}.fasta"

    colabfold_remote_msa.py \\
        --fasta "queries/${design_id}.fasta" \\
        --output search/ \\
        --max-wait-seconds 6900

    openfold3_msa.py finalise \\
        --input-pdb "${design_pdb}" \\
        --design-id "${design_id}" \\
        --binder-msa "search/${design_id}_0.a3m" \\
        --target-msa "search/${design_id}_1.a3m" \\
        --output-dir msas
    """
}
