#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: checks whether ProteinMPNN itself
// reproduces between NIM and non-NIM, isolated from RFdiffusion's own small
// backbone difference. Generates RFdiffusion seed 5 on both sides (Manuel's
// reported "good" seed, ~0.3 A backbone RMSD), then feeds EACH backbone into
// BOTH ProteinMPNN implementations (4 combinations), so backbone-driven and
// implementation-driven sequence differences can be told apart. Relax is
// skipped (relax_cycles=0) to isolate pure MPNN sequence design from
// structure relaxation.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.input_pdb = false
params.contigs = ''
params.hotspot_res = false
params.design_name = 'design_ppi'
params.rfd_command = 'python /app/RFdiffusion/scripts/run_inference.py'
params.rfd_noise_scale = 1
params.rfd_extra_args = 'inference.deterministic=True'
params.rfd_compress_trajectories = true
params.pmpnn_temperature = 0.000001
params.pmpnn_augment_eps = 0
params.pmpnn_omit_aas = 'CX'
params.pmpnn_seed = false

include { RFDIFFUSION } from './modules/local/rfd/rfdiffusion'
include { RFDIFFUSION_NIM } from './modules/local/rfd/rfdiffusion_nim'
include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_ON_OSS_BACKBONE } from './modules/local/rfd/dl_binder_design'
include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_ON_NIM_BACKBONE } from './modules/local/rfd/dl_binder_design'
include { DL_BINDER_DESIGN_PROTEINMPNN_NIM as MPNN_NIM_ON_OSS_BACKBONE } from './modules/local/rfd/dl_binder_design_nim'
include { DL_BINDER_DESIGN_PROTEINMPNN_NIM as MPNN_NIM_ON_NIM_BACKBONE } from './modules/local/rfd/dl_binder_design_nim'

workflow {
    ch_input_pdb = Channel.fromPath(params.input_pdb).first()

    def hotspot_res = params.hotspot_res
    if (params.hotspot_res) {
        hotspot_res = "[${params.hotspot_res.trim().replaceAll(/^\[+/, '').replaceAll(/\]+\$/, '')}]"
    }

    RFDIFFUSION(
        Channel.value(false),
        ch_input_pdb,
        Channel.value(false),
        params.contigs,
        hotspot_res,
        1,
        Channel.value(5),
        Channel.value('mpnnreposs'),
    )
    RFDIFFUSION_NIM(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        Channel.value(5),
        Channel.value('mpnnrepnim'),
        Channel.value(5),
    )

    ch_oss_backbone = RFDIFFUSION.out.pdbs.flatten()
    ch_nim_backbone = RFDIFFUSION_NIM.out.pdbs.flatten()

    MPNN_OSS_ON_OSS_BACKBONE(
        ch_oss_backbone, 1, 0, false,
        params.pmpnn_temperature, params.pmpnn_augment_eps, 0,
    )
    MPNN_OSS_ON_NIM_BACKBONE(
        ch_nim_backbone, 1, 0, false,
        params.pmpnn_temperature, params.pmpnn_augment_eps, 0,
    )
    MPNN_NIM_ON_OSS_BACKBONE(
        ch_oss_backbone.map { pdb -> tuple(pdb, 0) },
        'A',
        params.pmpnn_temperature,
    )
    MPNN_NIM_ON_NIM_BACKBONE(
        ch_nim_backbone.map { pdb -> tuple(pdb, 0) },
        'A',
        params.pmpnn_temperature,
    )
}
