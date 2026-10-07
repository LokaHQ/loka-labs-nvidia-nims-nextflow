#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: feeds the baseline run's already-generated
// threaded PDB into the NIM OpenFold3 path, to isolate implementation/precision
// differences from design-generation differences (RFdiffusion/ProteinMPNN are
// skipped entirely - same input sequence goes to both OpenFold3 implementations).
nextflow.enable.dsl = 2

params.outdir = 'results'
params.input_pdb = false

include { OPENFOLD3_MSA } from './modules/local/rfd/openfold3_msa'
include { OPENFOLD3_NIM } from './modules/local/rfd/openfold3_nim'

workflow {
    ch_input = Channel.of('precision_check_3ERYdgB')
        .combine(Channel.fromPath(params.input_pdb))

    OPENFOLD3_MSA(ch_input)
    OPENFOLD3_NIM(OPENFOLD3_MSA.out.designs_with_msas)
}
