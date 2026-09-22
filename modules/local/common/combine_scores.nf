process COMBINE_SCORES {
  container 'ghcr.io/australian-protein-design-initiative/containers/nf-binder-design-utils:0.1.6'

  publishDir "${params.outdir}/rfd", pattern: 'combined_scores.tsv', mode: 'copy'
  publishDir "${params.outdir}/rfd", pattern: 'binders.fasta', mode: 'copy'

  input:
  path 'af2ig_scores/*'
  path 'extra_scores.tsv'
  // TODO: boltz_scores must be optional, detected by dummy files ?
  path 'boltz_scores_complex.tsv'
  path 'rmsd_monomer_vs_complex.tsv'
  path 'rmsd_target_aligned_binder.tsv'
  path 'pdbs/*'

  output:
  path 'af2_initial_guess_scores.tsv', emit: af2_initial_guess_scores
  path 'extra_scores.tsv', emit: extra_scores
  path 'shape_scores.tsv', emit: shape_scores
  path 'combined_scores.tsv', emit: combined_scores
  path 'binders.fasta', emit: binders_fasta

  script:
  // Bare script names, not \${projectDir}/bin/... - that hardcodes the local
  // pipeline checkout path into the task script, which doesn't exist on remote
  // executors like AWS Batch. Nextflow auto-adds the top-level bin/ dir to PATH.
  """
    # Run the af2 score aggregation script
    af2_combine_scores.py af2ig_scores --output af2_initial_guess_scores.tsv

    # Run the shape score calculation script (Rg, Dmax, asphericity, Stokes Radius, chain, length, sequence)
    pushd pdbs
      calculate_shape_scores.py --chain A *.pdb >../shape_scores.tsv
    popd

    # Merge both tables
    merge_scores.py \
      af2_initial_guess_scores.tsv \
      shape_scores.tsv \
      extra_scores.tsv \
      --keys description,filename \
      --strip-suffix '(\\.pdb|_model_0\\.pdb)\$' \
        >prerefold_combined_scores.tsv

    # Only run this if the boltz scores and rmsd scores are non-empty files
    if [[ -s boltz_scores_complex.tsv && -s rmsd_monomer_vs_complex.tsv && -s rmsd_target_aligned_binder.tsv ]]; then
      # Merge boltz refolding scores with combined scores
      merge_scores.py \
        prerefold_combined_scores.tsv boltz_scores_complex.tsv \
        --column-prefix boltz_ \
        --keys id,description \
        >refold_combined_scores.tsv

      csvtk -t cut -b -f structure1,rmsd_all rmsd_monomer_vs_complex.tsv >tmp_monomer_rmsd.tsv

      merge_scores.py \
        refold_combined_scores.tsv tmp_monomer_rmsd.tsv \
        --column-prefix boltz_monomer_vs_complex_ \
        --keys structure1,description \
        --strip-suffix '(_model_0\\.pdb|_monomer)\$' \
        >rmsd1_scores.tsv

      csvtk -t cut -b -f structure1,rmsd_all rmsd_target_aligned_binder.tsv >tmp_target_aligned_binder_rmsd.tsv

      merge_scores.py \
        rmsd1_scores.tsv tmp_target_aligned_binder_rmsd.tsv \
        --column-prefix boltz_target_aligned_binder_ \
        --first-column filename,description,pae_interaction,plddt_binder,boltz_confidence_score,boltz_iptm,boltz_monomer_vs_complex_rmsd_all,boltz_target_aligned_binder_rmsd_all \
        --keys structure1,description \
        --strip-suffix '(\\.pdb|_model_0\\.pdb)\$' \
        >combined_scores.tsv

    else
      cp prerefold_combined_scores.tsv combined_scores.tsv && \
      rm prerefold_combined_scores.tsv
    fi


    # Output FASTA sequences of binders, with scores in the header
    pdb_to_fasta.py \
        --scores-table combined_scores.tsv \
        --scores pae_interaction,plddt_binder,rg,length \
        --chains A \
        pdbs/*.pdb \
      >binders.fasta
    """
}
