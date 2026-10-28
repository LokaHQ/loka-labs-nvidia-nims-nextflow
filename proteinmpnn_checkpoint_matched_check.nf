#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: the NIM vs non-NIM ProteinMPNN sequence
// comparison was confounded - NIM's bundled protein_mpnn_run.py defaults to
// checkpoint v_48_002 and used seed=102 (both visible in its own FASTA
// header), while our non-NIM path defaults to v_48_020 and (after the seeding
// patch) seed=0. So the ~50% sequence difference mixed an implementation
// difference with a different-model and different-seed difference.
//
// This runs the seed-patched non-NIM ProteinMPNN against NIM's checkpoint, to
// separate those out:
//   A) v_48_002, seed 0   -> isolates the checkpoint effect
//   B) v_48_002, seed 102 -> fully matched to NIM (checkpoint + seed)
// Both on GPU, same backbone, so device is matched too.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.backbone_pdb = false
params.pmpnn_temperature = 0.000001
params.pmpnn_augment_eps = 0
params.pmpnn_omit_aas = 'CX'
params.pmpnn_seed = false
params.nim_checkpoint = '/app/dl_binder_design/mpnn_fr/ProteinMPNN/vanilla_model_weights/v_48_002.pt'

include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_CKPT002_SEED0 } from './modules/local/rfd/dl_binder_design'
include { DL_BINDER_DESIGN_PROTEINMPNN as MPNN_OSS_CKPT002_SEED102 } from './modules/local/rfd/dl_binder_design'

workflow {
    ch_backbone = Channel.fromPath(params.backbone_pdb).first()

    MPNN_OSS_CKPT002_SEED0(
        ch_backbone, 1, 0, params.nim_checkpoint,
        params.pmpnn_temperature, params.pmpnn_augment_eps, 0,
    )
    MPNN_OSS_CKPT002_SEED102(
        ch_backbone, 1, 0, params.nim_checkpoint,
        params.pmpnn_temperature, params.pmpnn_augment_eps, 1,
    )
}
