#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: runs RFdiffusion twice at the same seed in
// the same arm, to measure one implementation's own run-to-run variance before
// reading the NIM-vs-no-NIM binder RMSD as a real cross-arm difference. Each
// task builds its own TensorRT engines (nothing mounts /cache/trt), so this
// also tells us whether engine builds are deterministic.
nextflow.enable.dsl = 2

params.input_pdb = false
params.contigs = '[A18-132/0 55-100]'
params.hotspot_res = 'A56,A63,A113,A123,A124'

// Defaults that normally come from workflows/rfd_openfold.nf, not nextflow.config.
params.design_name = 'design_ppi'
params.rfd_command = 'python /app/RFdiffusion/scripts/run_inference.py'
params.rfd_model_directory_path = false
params.rfd_noise_scale = 1
params.rfd_extra_args = ''
params.rfd_random_seed = 0
params.rfd_explicit_seed = true
params.rfd_compress_trajectories = true

include { RFDIFFUSION } from './modules/local/rfd/rfdiffusion'

workflow {
    def hotspot_res = params.hotspot_res
        ? "[${params.hotspot_res.trim().replaceAll(/^\[+/, '').replaceAll(/\]+$/, '')}]"
        : params.hotspot_res

    // Same design_startnum for both, so both land on the same seed. Only the
    // output prefix differs, which keeps the published PDBs from colliding.
    RFDIFFUSION(
        Channel.value(false),
        Channel.fromPath(params.input_pdb).first(),
        Channel.value(false),
        params.contigs,
        hotspot_res,
        1,
        Channel.value(0),
        Channel.of('noisefloorA', 'noisefloorB'),
    )
}
