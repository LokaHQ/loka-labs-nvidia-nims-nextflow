// Relaxes a structure ProteinMPNN has already threaded, so the baseline arm
// gets the same single-pass design-then-relax protocol as THREAD_AND_RELAX
// gives the NIM arm. Same container, same FastRelax XML.
process RELAX_ONLY {
    container 'ghcr.io/australian-protein-design-initiative/containers/proteinmpnn_dl_binder_design:latest'

    // Into a subdirectory, then published back under its own name: the
    // benchmark scripts match on a _mpnn<N> suffix, so the name must survive.
    publishDir path: "${params.outdir}/rfd/proteinmpnn_relaxed",
               pattern: 'relaxed/*.pdb',
               mode: 'copy',
               saveAs: { f -> file(f).name }

    input:
    path threaded_pdb

    output:
    path "relaxed/${threaded_pdb.name}", emit: pdbs

    script:
    """
    set -euo pipefail
    export CUDA_VISIBLE_DEVICES=""
    mkdir -p relaxed
    export RELAX_INPUT_PDB="${threaded_pdb}"
    export RELAX_OUTPUT_PDB="relaxed/${threaded_pdb.name}"
    export RELAX_XML="/app/dl_binder_design/mpnn_fr/RosettaFastRelaxUtil.xml"

    relax_only.py
    """
}
