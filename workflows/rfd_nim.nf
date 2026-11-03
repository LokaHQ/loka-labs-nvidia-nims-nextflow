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
params.pmpnn_seqs_per_struct = 1
params.pmpnn_temperature = 0.000001
params.of3_diffusion_samples = 1
// Unset keeps the public ColabFold API; set to a NIM base URL to use MSA Search.
params.rfd_random_seed = false
// Explicit per-design seeds, e.g. '0,5,34'. Overrides rfd_random_seed, which
// can only produce consecutive seeds (base + design index). Both pipelines must
// use the same list or designs cannot be paired.
params.rfd_seeds = false
// Designs served per OpenFold3 NIM task. The server boot is ~105 s against
// ~17 s of inference, so batching is what makes this arm measure the model
// rather than the startup. Must match rfd_openfold.nf for a fair comparison.
params.of3_batch_size = 1

// Designs served per RFdiffusion NIM task. Safe to raise: each design is a
// separate request with its own seed, so batching changes timing only.
params.rfd_batch_size = 1

params.msa_nim_url = false
// Must match what the baseline's colabfold_search actually reads. 'all' adds
// colabfold_envdb_202108, which the baseline does not host and runs with
// --use-env 0, so the NIM would search a larger database than the arm it is
// being compared against.
params.msa_nim_databases = 'uniref30'
// The baseline search returns 4,324 sequences for the PD-L1 target. Capping
// the NIM at 500 would not just change timing: MSA depth changes how OpenFold3
// folds the target, which lands in interface_dG and iptm and would read as a
// NIM effect. Note NIM_GLOBAL_MAX_MSA_DEPTH also defaults to 500 server-side,
// so the deployment may need raising too.
params.msa_nim_max_sequences = 10000
// colabfold_search runs at -e 0.1; bin/msa_search_nim.py defaults to 0.0001,
// a thousand times stricter.
params.msa_nim_e_value = 0.1
// Set to the databases on the FSx mount to run the MSA Search NIM in-task
// against the same files the baseline arm's colabfold_search reads. Unset
// leaves this arm on the public ColabFold API, which is NOT comparable with a
// self-hosted baseline - see the guard in the workflow body.
params.msa_db_dir = false
// The NIM loads the databases into GPU memory on start; this is the ceiling on
// 10s intervals before the task gives up.
params.msa_nim_ready_checks = 120
// false runs colabfold_search here instead of the MSA Search NIM, so both
// pipelines use the same MSA implementation and the step drops out of the
// comparison rather than being an unfair half of it. Needed while the NIM's
// g6e multi-GPU instances have no capacity.
params.msa_use_nim = true
// Must match rfd_openfold.nf exactly: both arms run OPENFOLD3_MSA_LOCAL, and
// undeclared here this resolves to null, leaving colabfold_search on its own
// defaults on this arm only - a silent asymmetry in the step that is supposed
// to contribute nothing, and a hard failure besides, since the default
// --use-env 1 needs an environmental database that is not hosted.
params.msa_local_search_args = '--db-load-mode 2 --use-env 0 --use-templates 0'
// A target alignment searched once and reused by every design; see the matching
// comment in rfd_openfold.nf. Takes precedence over msa_db_dir and msa_use_nim.
params.msa_target_a3m = false

include { UNIQUE_ID } from '../modules/local/common/unique_id'
include { RFDIFFUSION_NIM } from '../modules/local/rfd/rfdiffusion_nim'
include { DL_BINDER_DESIGN_PROTEINMPNN_NIM } from '../modules/local/rfd/dl_binder_design_nim'
include { THREAD_AND_RELAX } from '../modules/local/rfd/thread_and_relax'
include { OPENFOLD3_MSA } from '../modules/local/rfd/openfold3_msa'
include { OPENFOLD3_MSA_NIM } from '../modules/local/rfd/openfold3_msa_nim'
include { OPENFOLD3_MSA_LOCAL } from '../modules/local/rfd/openfold3_msa_local'
include { OPENFOLD3_MSA_PRECOMPUTED } from '../modules/local/rfd/openfold3_msa_precomputed'
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

    // One task per seed. The seed travels with the design index so the two
    // pipelines pair design-for-design even with non-consecutive seeds.
    def seed_list = params.rfd_seeds
        ? params.rfd_seeds.toString().tokenize(',').collect { it.trim() as int }
        : null
    if (seed_list && seed_list.size() != params.rfd_n_designs) {
        error("--rfd_seeds has ${seed_list.size()} seed(s) but --rfd_n_designs is ${params.rfd_n_designs}")
    }
    ch_design_seed = seed_list
        ? Channel.of(0..(params.rfd_n_designs - 1)).map { i -> tuple(i, seed_list[i]) }
        : Channel.of(0..(params.rfd_n_designs - 1)).map { i ->
            tuple(i, params.rfd_random_seed != false ? (params.rfd_random_seed as int) + i : false)
        }

    RFDIFFUSION_NIM(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        ch_design_seed
            .buffer(size: params.rfd_batch_size as int, remainder: true)
            .map { group ->
                tuple(group.collect { idx, _seed -> idx }, group.collect { _idx, seed -> seed })
            },
        ch_unique_id,
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

    // Self-hosted when msa_db_dir is set, matching the baseline arm. Otherwise
    // the public ColabFold API, which is only appropriate when the baseline is
    // on it too.
    if (params.msa_target_a3m) {
        OPENFOLD3_MSA_PRECOMPUTED(
            THREAD_AND_RELAX.out.designs,
            Channel.fromPath(params.msa_target_a3m, checkIfExists: true).first(),
        )
        ch_designs_with_msas = OPENFOLD3_MSA_PRECOMPUTED.out.designs_with_msas
        ch_msas = OPENFOLD3_MSA_PRECOMPUTED.out.msas
        ch_msa_queries = Channel.empty()
    }
    else if (params.msa_db_dir && params.msa_use_nim) {
        OPENFOLD3_MSA_NIM(THREAD_AND_RELAX.out.designs)
        ch_designs_with_msas = OPENFOLD3_MSA_NIM.out.designs_with_msas
        ch_msas = OPENFOLD3_MSA_NIM.out.msas
        ch_msa_queries = OPENFOLD3_MSA_NIM.out.queries
    }
    else if (params.msa_db_dir) {
        // Same search as the baseline pipeline. The MSA step then measures
        // nothing, which is honest - better than comparing a GPU NIM against a
        // CPU tool and calling the difference a pipeline result.
        OPENFOLD3_MSA_LOCAL(THREAD_AND_RELAX.out.designs)
        ch_designs_with_msas = OPENFOLD3_MSA_LOCAL.out.designs_with_msas
        ch_msas = OPENFOLD3_MSA_LOCAL.out.msas
        ch_msa_queries = OPENFOLD3_MSA_LOCAL.out.queries
    }
    else {
        OPENFOLD3_MSA(THREAD_AND_RELAX.out.designs)
        ch_designs_with_msas = OPENFOLD3_MSA.out.designs_with_msas
        ch_msas = OPENFOLD3_MSA.out.msas
        ch_msa_queries = OPENFOLD3_MSA.out.queries
    }

    // buffer size 1 keeps the default one-design-per-task shape; larger
    // batches serve several designs from a single NIM server boot.
    OPENFOLD3_NIM(
        ch_designs_with_msas
            .buffer(size: params.of3_batch_size as int, remainder: true)
            .map { group ->
                tuple(
                    group.collect { did, _pdb, _bm, _tm -> did },
                    group.collect { _did, pdb, _bm, _tm -> pdb },
                    group.collect { _did, _pdb, bm, _tm -> bm },
                    group.collect { _did, _pdb, _bm, tm -> tm },
                )
            }
    )

    // flatten: a batched task emits several PDBs, BindCraft scores one each.
    BINDCRAFT_SCORING_OPENFOLD3(
        OPENFOLD3_NIM.out.pdbs.flatten(),
        'A',
        'default_4stage_multimer',
        'rfd/openfold3_nim/extra_scores/',
    )

    emit:
    backbones = RFDIFFUSION_NIM.out.pdbs
    sequences = DL_BINDER_DESIGN_PROTEINMPNN_NIM.out.fasta
    threaded_pdbs = THREAD_AND_RELAX.out.pdbs
    msa_queries = ch_msa_queries
    msas = ch_msas
    refolded_pdbs = OPENFOLD3_NIM.out.pdbs.flatten()
    refold_scores = OPENFOLD3_NIM.out.scores
    predictions = OPENFOLD3_NIM.out.predictions
    raw_predictions = OPENFOLD3_NIM.out.raw
    bindcraft_scores = BINDCRAFT_SCORING_OPENFOLD3.out.scores
}
