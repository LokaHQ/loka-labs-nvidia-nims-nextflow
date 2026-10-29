#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: folds three ProteinMPNN sequences - all
// designed for the SAME RFdiffusion backbone (NIM, seed 5) - through the same
// folder, to answer two separate questions in one run:
//
//   1. Self-consistency: does each designed sequence fold back to the backbone
//      it was designed for? (the actual design-success metric)
//   2. Do sequences that differ from each other still give the same structure?
//
// The two sequences (the properly controlled pair, 74.4% identical):
//   seqNIM         - ProteinMPNN NIM (v_48_002, seed 102)
//   seqOSSmatched  - non-NIM, checkpoint+seed matched to NIM (v_48_002, seed 102)
// The earlier v_48_020/seed-0 sequence is deliberately excluded: its larger
// difference was mostly a checkpoint mismatch on our side, not an
// implementation difference.
//
// Uses the NIM folding path (OPENFOLD3_MSA -> OPENFOLD3_NIM) deliberately:
// MSA runs on the cheap CPU queue and carries the retry policy added after the
// public ColabFold API rate-limited the N=20 run. Which folder is used does not
// matter for this comparison, only that it is the same one for all three.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.backbone_pdb = false
params.nim_fasta = false
params.oss_matched_pdb = false

include { THREAD_AND_RELAX } from './modules/local/rfd/thread_and_relax'
include { OPENFOLD3_MSA } from './modules/local/rfd/openfold3_msa'
include { OPENFOLD3_NIM } from './modules/local/rfd/openfold3_nim'

workflow {
    // NIM's ProteinMPNN emits sequence only, so thread it onto the backbone
    // first. OpenFold3 folds from sequence, so this threading does not bias
    // the comparison against the already-threaded non-NIM PDBs.
    ch_to_thread = Channel.fromPath(params.backbone_pdb)
        .combine(Channel.fromPath(params.nim_fasta))

    THREAD_AND_RELAX(ch_to_thread)

    ch_already_threaded = Channel.of(
        tuple('seqOSSmatched', file(params.oss_matched_pdb)),
    )

    ch_designs = THREAD_AND_RELAX.out.designs.mix(ch_already_threaded)

    OPENFOLD3_MSA(ch_designs)
    OPENFOLD3_NIM(OPENFOLD3_MSA.out.designs_with_msas)
}
