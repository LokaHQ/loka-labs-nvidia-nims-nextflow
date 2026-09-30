#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
RFdiffusion -> ProteinMPNN -> OpenFold3 -> BindCraft scoring.

Core chain only - no Boltz-2 refold or FoldSeek (those are wired around AF2's
score format in rfd.nf; not adapted here yet). Stops at BindCraft's own
scores.tsv, doesn't feed into COMBINE_SCORES (that script expects AF2's
specific score columns/format, not adapted yet either).

Usage:
  nextflow run main.nf --method rfd_openfold --input_pdb target.pdb \
    --rfd_n_designs=4 --pmpnn_seqs_per_struct=2 -profile aws_batch_openfold
*/

params.input_pdb = false
params.outdir = 'results'
params.design_name = 'design_ppi'
params.contigs = ''
params.hotspot_res = false
params.rfd_n_designs = 2
params.rfd_command = 'python /app/RFdiffusion/scripts/run_inference.py'
params.rfd_model_directory_path = false
params.rfd_noise_scale = 0
params.rfd_extra_args = ''
params.rfd_compress_trajectories = true
params.pmpnn_seqs_per_struct = 1
params.pmpnn_relax_cycles = 3
params.pmpnn_weights = false
params.pmpnn_temperature = 0.000001
params.pmpnn_augment_eps = 0
params.pmpnn_omit_aas = 'CX'

include { UNIQUE_ID } from '../modules/local/common/unique_id'
include { RFDIFFUSION } from '../modules/local/rfd/rfdiffusion'
include { DL_BINDER_DESIGN_PROTEINMPNN } from '../modules/local/rfd/dl_binder_design'
include { OPENFOLD3 } from '../modules/local/rfd/openfold3'
include { BINDCRAFT_SCORING as BINDCRAFT_SCORING_AF2IG } from '../modules/local/rfd/bindcraft_scoring'

workflow RFD_OPENFOLD {

    main:

    if (params.input_pdb == false) {
        log.info(
            """
        ==================================================================
        PROTEIN BINDER DESIGN PIPELINE - RFDiffusion + OpenFold3
        ==================================================================
        Core chain only: RFdiffusion -> ProteinMPNN -> OpenFold3 -> BindCraft.

        Required arguments:
            --input_pdb           Input PDB file for the target

        Optional arguments:
            --outdir              Output directory [default: ${params.outdir}]
            --contigs             Contig map for RFdiffusion [default: ${params.contigs}]
            --hotspot_res         Hotspot residues, eg "A56" - chain ID required [default: ${params.hotspot_res}]
            --rfd_n_designs       Number of RFdiffusion designs [default: ${params.rfd_n_designs}]
            --pmpnn_seqs_per_struct Number of ProteinMPNN sequences per backbone [default: ${params.pmpnn_seqs_per_struct}]
            --pmpnn_temperature   Sampling temperature for ProteinMPNN [default: ${params.pmpnn_temperature}]
        """.stripIndent()
        )
        exit(1)
    }

    UNIQUE_ID()
    ch_unique_id = UNIQUE_ID.out.id_file.map { it.text.trim() }

    ch_input_pdb = Channel.fromPath(params.input_pdb).first()

    def hotspot_res = params.hotspot_res
    if (params.hotspot_res) {
        hotspot_res = "[${params.hotspot_res.trim().replaceAll(/^\[+/, '').replaceAll(/\]+\$/, '')}]"
    }

    ch_rfd_startnum = Channel.of(0..(params.rfd_n_designs - 1))

    RFDIFFUSION(
        Channel.value(false),
        ch_input_pdb,
        Channel.value(false),
        params.contigs,
        hotspot_res,
        1,
        ch_rfd_startnum,
        ch_unique_id,
    )
    ch_backbones = RFDIFFUSION.out.pdbs.flatten()

    ch_pmpnn_inputs = ch_backbones
        | combine(Channel.of(0..(params.pmpnn_seqs_per_struct - 1)))

    DL_BINDER_DESIGN_PROTEINMPNN(
        ch_pmpnn_inputs.map { pdb, idx -> pdb },
        Channel.value(1),
        params.pmpnn_relax_cycles,
        params.pmpnn_weights,
        params.pmpnn_temperature,
        params.pmpnn_augment_eps,
        ch_pmpnn_inputs.map { pdb, idx -> idx },
    )

    OPENFOLD3(
        DL_BINDER_DESIGN_PROTEINMPNN.out.pdbs
    )

    BINDCRAFT_SCORING_AF2IG(
        OPENFOLD3.out.pdbs,
        'A',
        'default_4stage_multimer',
        'rfd/openfold3/extra_scores/',
    )

    emit:
    backbones = RFDIFFUSION.out.pdbs
    openfold3_pdbs = OPENFOLD3.out.pdbs
    scores = BINDCRAFT_SCORING_AF2IG.out.scores
}
