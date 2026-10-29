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
//
// The engines are built for SM89, so this only runs on L40S (g6e). Anything
// else will not find usable engines.
process RFDIFFUSION_STANDALONE {
    publishDir path: "${params.outdir}/rfd/rfdiffusion", pattern: 'pdbs/*.pdb', mode: 'copy'
    publishDir path: "${params.outdir}/rfd/rfdiffusion", pattern: 'metadata/*.json', mode: 'copy'

    input:
    path input_pdb
    val contigs
    val hotspot_res
    tuple val(design_startnum), val(random_seed)
    val unique_id

    output:
    path 'pdbs/*.pdb', emit: pdbs
    path 'metadata/*.json', emit: metadata

    script:
    def design_id = "${params.design_name}_${unique_id}_${design_startnum}"
    def hotspot_arg = hotspot_res ? "--hotspot-res '${hotspot_res}'" : ''
    // The caller passes the actual seed, not a base to offset, so a run can
    // use arbitrary seeds (0,5,34) rather than only consecutive ones.
    def seed_arg = random_seed != false ? "--seed ${random_seed as int}" : ''
    // Matching the NIM needs its startup warmup here too: the reference 15-seed
    // parity run carried one (350 residues, 15 steps, seed 1234, ~53 s) against
    // the PDB baked into the NIM image. Every task is a fresh container, so this
    // is paid per design, not once per server.
    def warmup_arg = params.rfd_nim_warmup_pdb
        ? "--nim-warmup-pdb ${params.rfd_nim_warmup_pdb}"
        : ''
    """
    set -euo pipefail
    mkdir -p pdbs metadata

    export NIM_CACHE_PATH="\$PWD/nim-cache"
    mkdir -p "\${NIM_CACHE_PATH}"

    # The image ships no weights - the NIM normally fetches them when its server
    # starts, which nothing does here. Pull them with the NIM's own downloader,
    # then drop the key so inference cannot reach NGC and quietly differ from a
    # run without one.
    if [ -n "${params.ngc_api_key_secret ?: ''}" ]; then
        export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \\
            --secret-id "${params.ngc_api_key_secret ?: ''}" \\
            --region "${params.ngc_api_key_region}" \\
            --query SecretString \\
            --output text)
    fi
    if [ -z "\${NGC_API_KEY:-}" ]; then
        echo "NGC_API_KEY is unavailable; the model download needs it" >&2
        exit 1
    fi

    ( cd /opt/nim && env PYTHONPATH=/opt/nim python3 -c \\
        'from nimlib import nimutils; nimutils.download_models(nimutils.get_model_manifest())' )
    unset NGC_API_KEY NVIDIA_API_KEY

    MODEL_DIR="${params.rfd_model_directory_path ?: ''}"
    if [ -z "\${MODEL_DIR}" ]; then
        MODEL_DIR="\${NIM_CACHE_PATH}/ngc/hub/models--nim--ipd--rfdiffusion/snapshots/${params.rfd_nim_model_version}"
    fi

    rfdiffusion_2_standalone.py \\
        --input-pdb "${input_pdb}" \\
        --output-pdb "pdbs/${design_id}.pdb" \\
        --metadata-json "metadata/${design_id}.json" \\
        --contigs '${contigs}' \\
        ${hotspot_arg} \\
        --diffusion-steps ${params.rfd_diffusion_steps ?: 50} \\
        ${seed_arg} \\
        --model-directory "\${MODEL_DIR}" \\
        ${warmup_arg}
    """
}
