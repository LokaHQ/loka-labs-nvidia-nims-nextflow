#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: re-runs the NIM-vs-non-NIM ProteinMPNN
// cross-comparison (see proteinmpnn_repro_check.nf) using the seed-patched,
// now-100%-self-reproducible non-NIM image, to see whether fixing non-NIM's
// own non-determinism changes the true NIM-vs-non-NIM gap. NIM side is
// unaffected by the patch and already run (same backbones) - only the
// non-NIM side needs to be regenerated here, against each of the two
// already-generated backbones (from proteinmpnn_repro_check.nf).
nextflow.enable.dsl = 2

params.outdir = 'results'
params.oss_backbone = false
params.nim_backbone = false
params.pmpnn_temperature = 0.000001
params.pmpnn_augment_eps = 0
params.pmpnn_omit_aas = 'CX'

include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_PATCHED_ON_OSS_BACKBONE } from './modules/local/rfd/dl_binder_design'
include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_PATCHED_ON_NIM_BACKBONE } from './modules/local/rfd/dl_binder_design'

workflow {
    ch_oss_backbone = Channel.fromPath(params.oss_backbone).first()
    ch_nim_backbone = Channel.fromPath(params.nim_backbone).first()

    MPNN_OSS_PATCHED_ON_OSS_BACKBONE(
        ch_oss_backbone, 1, 0, false,
        params.pmpnn_temperature, params.pmpnn_augment_eps, 0,
    )
    MPNN_OSS_PATCHED_ON_NIM_BACKBONE(
        ch_nim_backbone, 1, 0, false,
        params.pmpnn_temperature, params.pmpnn_augment_eps, 0,
    )
}
