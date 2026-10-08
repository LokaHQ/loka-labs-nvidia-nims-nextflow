#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
NIM binder design on AWS Batch: RFdiffusion -> ProteinMPNN -> thread/relax
-> unpaired per-chain MSA search -> OpenFold3 co-folding
-> BindCraft-derived interface scoring.
Each NIM runs as a batch task.
The threaded complex supplies binder A and the cropped target B sequences;
OpenFold3 does not use its coordinates as an initial guess.
*/

params.input_pdb = false
params.outdir = 'results'
params.contigs = ''
params.hotspot_res = false
params.rfd_n_designs = 2
params.rfd_random_seed = false
params.pmpnn_seqs_per_struct = 1
params.pmpnn_temperature = 0.000001
params.of3_diffusion_samples = 1

include { UNIQUE_ID } from '../modules/local/common/unique_id'
include { RFDIFFUSION_NIM } from '../modules/local/rfd/rfdiffusion_nim'
include { DL_BINDER_DESIGN_PROTEINMPNN_NIM } from '../modules/local/rfd/dl_binder_design_nim'
include { THREAD_AND_RELAX } from '../modules/local/rfd/thread_and_relax'
include { OPENFOLD3_MSA } from '../modules/local/rfd/openfold3_msa'
include { OPENFOLD3_NIM } from '../modules/local/rfd/openfold3_nim'
include { BINDCRAFT_SCORING as BINDCRAFT_SCORING_OPENFOLD3 } from '../modules/local/rfd/bindcraft_scoring'

workflow RFD_NIM {

    main:

    if (params.input_pdb == false) {
        log.info(
            """
        ==================================================================
        PROTEIN BINDER DESIGN PIPELINE - RFDiffusion NIM proof of concept
        ==================================================================
        Covers RFdiffusion + ProteinMPNN via their NVIDIA NIM containers, threads
        and relaxes the designed sequence onto the backbone, searches independent
        binder and target MSAs, then co-folds and scores the complex with the
        OpenFold3 NIM in place of AF2 initial guess. Every OpenFold3 prediction
        then receives BindCraft-derived interface scores.

        Required arguments:
            --input_pdb           Input PDB file for the target

        Optional arguments:
            --outdir              Output directory [default: ${params.outdir}]
            --contigs             Contig map for RFdiffusion [default: ${params.contigs}]
            --hotspot_res         Hotspot residues, eg "A56" - chain ID required [default: ${params.hotspot_res}]
            --rfd_n_designs       Number of RFdiffusion designs [default: ${params.rfd_n_designs}]
            --pmpnn_seqs_per_struct Number of ProteinMPNN sequences per backbone [default: ${params.pmpnn_seqs_per_struct}]
            --pmpnn_temperature   Sampling temperature for ProteinMPNN [default: ${params.pmpnn_temperature}]
            --of3_diffusion_samples Must be 1 to preserve one structure per design
        """.stripIndent()
        )
        exit(1)
    }

    if (params.of3_diffusion_samples.toString() != '1') {
        error('rfd_nim requires --of3_diffusion_samples 1 to preserve one prediction per design')
    }

    if (!params.ngc_api_key_secret && !System.getenv('NGC_API_KEY')) {
        log.error("NIM authentication is unavailable. Set NGC_API_KEY in the launch environment or configure --ngc_api_key_secret with an AWS Secrets Manager secret ID.")
        exit(1)
    }

    UNIQUE_ID()
    ch_unique_id = UNIQUE_ID.out.id_file.map { id_file -> id_file.text.trim() }

    ch_input_pdb = Channel.fromPath(params.input_pdb, checkIfExists: true).toList().map { pdbs ->
        if (pdbs.size() != 1) {
            error('rfd_nim requires exactly one target PDB per run')
        }
        pdbs[0]
    }

    def hotspot_res = params.hotspot_res
    if (params.hotspot_res) {
        hotspot_res = "[${params.hotspot_res.trim().replaceAll(/^\[+/, '').replaceAll(/\]+\$/, '')}]"
    }

    ch_design_index = Channel.of(0..(params.rfd_n_designs - 1))

    RFDIFFUSION_NIM(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        ch_design_index,
        ch_unique_id,
        params.rfd_random_seed,
    )

    ch_pmpnn_inputs = RFDIFFUSION_NIM.out.pdbs.flatten()
        | combine(Channel.of(0..(params.pmpnn_seqs_per_struct - 1)))

    DL_BINDER_DESIGN_PROTEINMPNN_NIM(
        ch_pmpnn_inputs,
        'A',
        params.pmpnn_temperature,
    )

    THREAD_AND_RELAX(
        DL_BINDER_DESIGN_PROTEINMPNN_NIM.out.backbone_with_fasta,
    )

    OPENFOLD3_MSA(
        THREAD_AND_RELAX.out.designs,
    )

    OPENFOLD3_NIM(
        OPENFOLD3_MSA.out.designs_with_msas,
    )

    BINDCRAFT_SCORING_OPENFOLD3(
        OPENFOLD3_NIM.out.pdbs,
        'A',
        'default_4stage_multimer',
        'rfd/openfold3_nim/extra_scores/',
    )

    emit:
    backbones = RFDIFFUSION_NIM.out.pdbs
    sequences = DL_BINDER_DESIGN_PROTEINMPNN_NIM.out.fasta
    threaded_pdbs = THREAD_AND_RELAX.out.pdbs
    msa_queries = OPENFOLD3_MSA.out.queries
    msas = OPENFOLD3_MSA.out.msas
    refolded_pdbs = OPENFOLD3_NIM.out.pdbs
    refold_scores = OPENFOLD3_NIM.out.scores
    predictions = OPENFOLD3_NIM.out.predictions
    raw_predictions = OPENFOLD3_NIM.out.raw
    bindcraft_scores = BINDCRAFT_SCORING_OPENFOLD3.out.scores
}
