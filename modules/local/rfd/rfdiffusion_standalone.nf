// RFdiffusion via the standalone runner in the rfdiffusion-fixed image, which
// reproduces the NIM's inference path (its RNG setup, TF32 and final-sequence
// handling) without the NIM's HTTP server. Same seed, same backbone as the NIM
// arm - verified at 0.00 A across 15 seeds outside the pipeline.
//
// Separate from RFDIFFUSION because it is a different program, not a different
// container: it takes an explicit CLI rather than Hydra overrides, and emits
// one PDB plus a metadata JSON instead of trajectories, Hydra configs and logs.
//
// Note the comparison this enables is of the serving layer - HTTP and container
// overhead - not of two independent implementations. Both sides run NVIDIA's
// code on NVIDIA's prebuilt TensorRT engines.
process RFDIFFUSION_STANDALONE {
    publishDir path: "${params.outdir}/rfd/rfdiffusion", pattern: 'pdbs/*.pdb', mode: 'copy'
    publishDir path: "${params.outdir}/rfd/rfdiffusion", pattern: 'metadata/*.json', mode: 'copy'

    input:
    path input_pdb
    val contigs
    val hotspot_res
    val design_startnum
    val unique_id
    val random_seed

    output:
    path 'pdbs/*.pdb', emit: pdbs
    path 'metadata/*.json', emit: metadata

    script:
    def design_id = "${params.design_name}_${unique_id}_${design_startnum}"
    def hotspot_arg = hotspot_res ? "--hotspot-res '${hotspot_res}'" : ''
    // Design N uses seed N, matching RFDIFFUSION and RFDIFFUSION_NIM. One
    // design per task, so the offset is just the start number.
    def seed_arg = random_seed != false
        ? "--seed ${(random_seed as int) + (design_startnum as int)}"
        : ''
    def model_dir_arg = params.rfd_model_directory_path
        ? "--model-directory ${params.rfd_model_directory_path}"
        : ''
    // The NIM server runs a 350-residue warmup at startup; the runner calls its
    // own copy of it a "reproducibility warmup". If GPU state from that warmup
    // affects later results, matching the NIM needs it here too - and every task
    // is a fresh container, so it would be paid per design, not per server.
    def warmup_arg = params.rfd_nim_warmup_pdb
        ? "--nim-warmup-pdb ${params.rfd_nim_warmup_pdb}"
        : ''
    """
    set -euo pipefail
    mkdir -p pdbs metadata

    # Built on the NIM image, so the runner resolves weights through the NIM's
    # own helper and may need a key to reach them.
    if [ -n "${params.ngc_api_key_secret ?: ''}" ]; then
        export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \\
            --secret-id "${params.ngc_api_key_secret ?: ''}" \\
            --region "${params.ngc_api_key_region}" \\
            --query SecretString \\
            --output text)
    fi

    rfdiffusion_2_standalone.py \\
        --input-pdb "${input_pdb}" \\
        --output-pdb "pdbs/${design_id}.pdb" \\
        --metadata-json "metadata/${design_id}.json" \\
        --contigs '${contigs}' \\
        ${hotspot_arg} \\
        --diffusion-steps ${params.rfd_diffusion_steps ?: 50} \\
        ${seed_arg} \\
        ${model_dir_arg} \\
        ${warmup_arg}
    """
}
