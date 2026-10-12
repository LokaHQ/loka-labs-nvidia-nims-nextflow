#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: runs OSS RFdiffusion and RFdiffusion-NIM
// for 15 diffusion steps (the minimum OSS allows - T<15 is rejected by
// RFdiffusion's own code as "badly approximated"), instead of the normal 50,
// same seed on both sides, to see whether a "good" seed (small final RMSD)
// and a "bad" seed (large final RMSD) already disagree early in the
// trajectory - distinguishing a real per-step numerical difference from pure
// compounding over the full 50-step trajectory.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.input_pdb = false
params.contigs = ''
params.hotspot_res = false
params.design_name = 'design_ppi'
params.rfd_command = 'python /app/RFdiffusion/scripts/run_inference.py'
params.rfd_noise_scale = 1
params.rfd_extra_args = ''
params.rfd_compress_trajectories = true

include { RFDIFFUSION as RFDIFFUSION_SEED5 } from './modules/local/rfd/rfdiffusion'
include { RFDIFFUSION as RFDIFFUSION_SEED34 } from './modules/local/rfd/rfdiffusion'
include { RFDIFFUSION_NIM as RFDIFFUSION_NIM_SEED5 } from './modules/local/rfd/rfdiffusion_nim'
include { RFDIFFUSION_NIM as RFDIFFUSION_NIM_SEED34 } from './modules/local/rfd/rfdiffusion_nim'

workflow {
    ch_input_pdb = Channel.fromPath(params.input_pdb).first()

    def hotspot_res = params.hotspot_res
    if (params.hotspot_res) {
        hotspot_res = "[${params.hotspot_res.trim().replaceAll(/^\[+/, '').replaceAll(/\]+\$/, '')}]"
    }

    RFDIFFUSION_SEED5(
        Channel.value(false),
        ch_input_pdb,
        Channel.value(false),
        params.contigs,
        hotspot_res,
        1,
        Channel.value(5),
        Channel.value('fsteposs5'),
    )
    RFDIFFUSION_SEED34(
        Channel.value(false),
        ch_input_pdb,
        Channel.value(false),
        params.contigs,
        hotspot_res,
        1,
        Channel.value(34),
        Channel.value('fsteposs34'),
    )

    RFDIFFUSION_NIM_SEED5(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        Channel.value(5),
        Channel.value('fstepnim5'),
        Channel.value(5),
        Channel.value(15),
    )
    RFDIFFUSION_NIM_SEED34(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        Channel.value(34),
        Channel.value('fstepnim34'),
        Channel.value(34),
        Channel.value(15),
    )
}
