#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: runs OSS OpenFold3 and NIM OpenFold3 each
// a second, independent time on the same already-generated threaded PDB, to
// measure each implementation's own run-to-run variance (noise floor) before
// attributing the OSS-vs-NIM diff in precision_check.nf to precision itself.
nextflow.enable.dsl = 2

params.outdir = 'results'
params.input_pdb = false

include { OPENFOLD3 } from './modules/local/rfd/openfold3'
include { OPENFOLD3_MSA } from './modules/local/rfd/openfold3_msa'
include { OPENFOLD3_NIM } from './modules/local/rfd/openfold3_nim'

workflow {
    ch_oss_input = Channel.fromPath(params.input_pdb)
    OPENFOLD3(ch_oss_input.collect())

    ch_nim_input = Channel.of('noise_floor_3ERYdgB')
        .combine(Channel.fromPath(params.input_pdb))
    OPENFOLD3_MSA(ch_nim_input)
    OPENFOLD3_NIM(OPENFOLD3_MSA.out.designs_with_msas)
}
