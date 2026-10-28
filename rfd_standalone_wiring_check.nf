#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: smallest run that answers what reading the
// rfdiffusion-fixed image cannot.
//
//   1. Does the standalone runner work under Batch at all - does it need the
//      NGC key, and does it download anything at startup?
//   2. Does it skip the ~31 min TensorRT engine build? It ships prebuilt
//      engines, so the task should be minutes, not half an hour.
//   3. Does it reproduce the NIM at the same seed inside the pipeline, with
//      the warmup the reference parity run used? That run measured 0.00 A.
//
// One seed, one design per arm. The warmup is on by default because the
// reference parity run carried it; rerun with --rfd_nim_warmup_pdb false to
// measure what it is actually worth, since it costs ~53 s per design.
nextflow.enable.dsl = 2

params.input_pdb = false
params.contigs = '[A18-132/0 78-78]'
params.hotspot_res = 'A56'
params.rfd_random_seed = 0
params.outdir = 'results-standalone-wiring'

// Defaults that normally come from workflows/rfd_openfold.nf.
params.design_name = 'design_ppi'
params.rfd_model_directory_path = false
params.rfd_diffusion_steps = 50
// The reference parity run carried the NIM's warmup, so match it by default.
params.rfd_nim_warmup_pdb = '/opt/nim/5TPN.pdb'
params.rfd_nim_model_version = '2.3.0'

include { RFDIFFUSION_STANDALONE } from './modules/local/rfd/rfdiffusion_standalone'
include { RFDIFFUSION_NIM } from './modules/local/rfd/rfdiffusion_nim'

process COMPARE_BACKBONES {
    container "${params.ecr_base}:nf-binder-design-utils"
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path 'pdbs/*'

    output:
    path 'backbone_rmsd.tsv'

    script:
    """
    set -euo pipefail
    rmsd4all.py pdbs/ --output backbone_rmsd.tsv
    """
}

workflow {
    if (!params.input_pdb) {
        error('--input_pdb is required')
    }

    def hotspot_res = params.hotspot_res
        ? "[${params.hotspot_res.trim().replaceAll(/^\[+/, '').replaceAll(/\]+$/, '')}]"
        : params.hotspot_res

    ch_input_pdb = Channel.fromPath(params.input_pdb, checkIfExists: true).first()

    RFDIFFUSION_STANDALONE(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        Channel.value(tuple(0, params.rfd_random_seed)),
        Channel.value('standalone'),
    )

    RFDIFFUSION_NIM(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        Channel.value(tuple(0, params.rfd_random_seed)),
        Channel.value('nim'),
    )

    COMPARE_BACKBONES(
        RFDIFFUSION_STANDALONE.out.pdbs.mix(RFDIFFUSION_NIM.out.pdbs).collect()
    )
}
