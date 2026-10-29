#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: checks whether each ProteinMPNN
// implementation (NIM, non-NIM) reproduces itself - same backbone, same
// implementation, run twice. Follow-up to proteinmpnn_repro_check.nf, which
// found NIM and non-NIM only agree ~50% on sequence identity given an
// identical backbone; this isolates whether each side is even
// self-consistent before blaming the implementation-vs-implementation gap.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.backbone_pdb = false
params.pmpnn_temperature = 0.000001
params.pmpnn_augment_eps = 0
params.pmpnn_omit_aas = 'CX'
params.pmpnn_seed = false

params.run_nim = true

include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_RUN1 } from './modules/local/rfd/dl_binder_design'
include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_RUN2 } from './modules/local/rfd/dl_binder_design'
include { DL_BINDER_DESIGN_PROTEINMPNN_NIM as MPNN_NIM_RUN1 } from './modules/local/rfd/dl_binder_design_nim'
include { DL_BINDER_DESIGN_PROTEINMPNN_NIM as MPNN_NIM_RUN2 } from './modules/local/rfd/dl_binder_design_nim'

workflow {
    ch_backbone = Channel.fromPath(params.backbone_pdb).first()

    MPNN_OSS_RUN1(ch_backbone, 1, 0, false, params.pmpnn_temperature, params.pmpnn_augment_eps, 0)
    MPNN_OSS_RUN2(ch_backbone, 1, 0, false, params.pmpnn_temperature, params.pmpnn_augment_eps, 1)

    if (params.run_nim) {
        MPNN_NIM_RUN1(ch_backbone.map { pdb -> tuple(pdb, 0) }, 'A', params.pmpnn_temperature)
        MPNN_NIM_RUN2(ch_backbone.map { pdb -> tuple(pdb, 1) }, 'A', params.pmpnn_temperature)
    }
}
