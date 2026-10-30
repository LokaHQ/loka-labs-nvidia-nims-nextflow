#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: measures whether persisting the container's
// XDG_CACHE_HOME (TensorRT engines + Warp/CUDA JIT) cuts RFdiffusion's ~31 min
// cold start, and whether a cache warmed at one binder length helps another.
//
// Engines are namespaced by sequence length, so the cross-length arm is the one
// that decides whether caching is worth it for a 55-100 range. Contigs are
// pinned to a single length per arm so length is controlled, not sampled.
//
//   WARM        len A, no cache  -> builds, publishes cache.tar
//   SAME_LEN    len A, w/ cache  -> best case, full hit
//   DIFF_LEN    len B, w/ cache  -> shared JIT only, engines rebuilt
nextflow.enable.dsl = 2

params.input_pdb = false
params.hotspot_res = 'A56,A63,A113,A123,A124'
params.target_contig = 'A18-132'
params.len_a = 79
params.len_b = 63
params.design_name = 'design_ppi'
params.rfd_command = 'python /app/RFdiffusion/scripts/run_inference.py'
params.rfd_noise_scale = 1
params.outdir = 'results-trt-cache'

def hotspots = "[${params.hotspot_res}]"

// Shared body. cache_in is either a real tar or the EMPTY placeholder; the
// restore is skipped for the placeholder so WARM starts genuinely cold.
def rfdBody = { length, seed, save_cache ->
    """
    set -euo pipefail
    export HOME=/tmp
    # Engines go to RFDIFFUSION_TRT_CACHE (nim_service_utils.get_trt_engine_dir_path),
    # not XDG_CACHE_HOME - the latter only holds the Warp/JIT side.
    export XDG_CACHE_HOME=\$PWD/trtcache/xdg
    export RFDIFFUSION_TRT_CACHE=\$PWD/trtcache/trt
    mkdir -p \$XDG_CACHE_HOME \$RFDIFFUSION_TRT_CACHE outputs schedules

    if [ -s cache_in.tar ]; then
        echo "[cache] restoring \$(du -sh cache_in.tar | cut -f1)" | tee -a run.log
        tar -xf cache_in.tar -C \$PWD/trtcache
        echo "[cache] restored \$(find \$PWD/trtcache -type f | wc -l) files, \
engines=\$(find \$RFDIFFUSION_TRT_CACHE -type f | wc -l)" | tee -a run.log
    else
        echo "[cache] cold start, no cache supplied" | tee -a run.log
    fi

    start=\$(date +%s)
    ${params.rfd_command} \\
        inference.output_prefix=outputs/${params.design_name} \\
        inference.input_pdb=${params.input_pdb ? 'target.pdb' : ''} \\
        contigmap.contigs='[${params.target_contig}/0 ${length}-${length}]' \\
        ppi.hotspot_res='${hotspots}' \\
        denoiser.noise_scale_ca=${params.rfd_noise_scale} \\
        denoiser.noise_scale_frame=${params.rfd_noise_scale} \\
        inference.num_designs=1 \\
        inference.design_startnum=0 \\
        inference.schedule_directory_path=schedules \\
        inference.write_trajectory=false \\
        inference.deterministic=True \\
        inference.random_seed=${seed} 2>&1 | tee -a run.log
    end=\$(date +%s)

    echo "WALL_SECONDS=\$((end-start))" | tee -a run.log
    ${save_cache ? '''echo "[cache] saving engines=$(find $RFDIFFUSION_TRT_CACHE -type f | wc -l) \
total=$(du -sh $PWD/trtcache | cut -f1)" | tee -a run.log
    tar -cf cache_out.tar -C $PWD/trtcache .''' : 'touch cache_out.tar'}
    """
}

process WARM {
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:rfdiffusion-nim-code-updated'
    publishDir "${params.outdir}/warm", pattern: 'run.log', mode: 'copy'
    input:
    path 'target.pdb'
    path 'cache_in.tar'
    output:
    path 'cache_out.tar', emit: cache
    path 'run.log', emit: log
    script:
    rfdBody(params.len_a, 0, true)
}

process SAME_LEN {
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:rfdiffusion-nim-code-updated'
    publishDir "${params.outdir}/same_len", pattern: 'run.log', mode: 'copy'
    input:
    path 'target.pdb'
    path 'cache_in.tar'
    output:
    path 'run.log', emit: log
    script:
    rfdBody(params.len_a, 1, false)
}

process DIFF_LEN {
    container '520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims:rfdiffusion-nim-code-updated'
    publishDir "${params.outdir}/diff_len", pattern: 'run.log', mode: 'copy'
    input:
    path 'target.pdb'
    path 'cache_in.tar'
    output:
    path 'run.log', emit: log
    script:
    rfdBody(params.len_b, 0, false)
}

workflow {
    ch_pdb = Channel.fromPath(params.input_pdb).first()
    // Zero-byte stand-in so the cold arm takes the same input cardinality.
    ch_empty = Channel.fromPath("${baseDir}/assets/EMPTY_CACHE.tar").first()

    WARM(ch_pdb, ch_empty)
    SAME_LEN(ch_pdb, WARM.out.cache)
    DIFF_LEN(ch_pdb, WARM.out.cache)
}
