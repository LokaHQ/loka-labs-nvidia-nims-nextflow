#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: runs OSS RFdiffusion (inference.deterministic=true,
// design index 0) and RFdiffusion-NIM (random_seed=0) on the identical target/contigs/
// hotspot, to test whether seeding both implementations the same way produces matching
// backbones - the empirical follow-up to the confirmed fp16-vs-fp32 precision gap.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.input_pdb = false
params.contigs = ''
params.hotspot_res = false
params.design_name = 'design_ppi'
params.rfd_command = 'python /app/RFdiffusion/scripts/run_inference.py'
params.rfd_noise_scale = 0
params.rfd_extra_args = ''
params.rfd_compress_trajectories = true

include { RFDIFFUSION } from './modules/local/rfd/rfdiffusion'
include { RFDIFFUSION_NIM } from './modules/local/rfd/rfdiffusion_nim'

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
        Channel.value(0),
        Channel.value('seedchkoss'),
    )

    RFDIFFUSION_NIM(
        ch_input_pdb,
        params.contigs,
        hotspot_res,
        Channel.value(0),
        Channel.value('seedchknim'),
        Channel.value(0),
    )
}
