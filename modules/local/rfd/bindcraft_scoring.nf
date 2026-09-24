process BINDCRAFT_SCORING {
  container 'ghcr.io/australian-protein-design-initiative/containers/bindcraft:0366085-nv-cuda120'

  publishDir path: "${params.outdir}/${extra_scores_publish_dir}", pattern: '*.tsv', mode: 'copy'

  input:
  path pdb_file
  val binder_chain
  val advanced_settings_preset
  val extra_scores_publish_dir

  output:
  path '*.tsv', emit: scores

  script:
  """
    # Script moved to top-level bin/ (was bin/bindcraft/) - Nextflow only PATH-exports
    # the top-level bin/ dir, not nested subdirectories, so a nested script is
    # invisible to \$(which ...) here otherwise. Resolved via \$(which ...) rather
    # than a bare name since this needs the BindCraft conda env's python
    # specifically (its own shebang is a generic #!/usr/bin/env python).
    /opt/conda/envs/BindCraft/bin/python "\$(which bindcraft_scoring.py)" \
      --format tsv \
      --output ${pdb_file.simpleName}.tsv \
      --binder-chain ${binder_chain} \
      --dalphaball-path /app/BindCraft/functions/DAlphaBall.gcc \
      --dssp-path /app/BindCraft/functions/dssp \
      ${pdb_file}

    # We don't use this, just the default (which is already CX)
    # --omit-aas ${params.pmpnn_omit_aas}
    """
}
