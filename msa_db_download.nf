#!/usr/bin/env nextflow
// Ad-hoc, not part of the pipeline: loads the MSA databases onto the FSx mount
// once, so both benchmark arms can search the same files.
//
// Downloads the NIM's own copy from NGC first, then checks whether
// colabfold_search can read that same layout. Both arms sharing one copy keeps
// the filesystem at ~1.2 TB and, more importantly, removes any doubt that the
// two tools searched identical data. If the layouts turn out to be
// incompatible, ColabFold's own copy has to be fetched as well (~0.8 TB more,
// still inside the 2,400 GB).
//
// Run once:
//   nextflow run msa_db_download.nf -profile aws_batch_nims \
//     -c ad_hoc_msa_db_download.config
nextflow.enable.dsl = 2

params.msa_mount = '/fsx'
params.msa_db_dir = '/fsx/msa'
// 'all' is uniref30 + colabfold_envdb + the PDB sets, matching what the public
// ColabFold API searched in every run so far. ~1.2 TB.
params.msa_nim_profile = 'all'
params.outdir = 'results'

process DOWNLOAD_NIM_DATABASES {
    publishDir "${params.outdir}/msa-db", mode: 'copy'

    output:
    path 'download_report.txt'

    script:
    """
    set -euo pipefail

    if [ ! -d "${params.msa_mount}" ]; then
        echo "FSx not mounted at ${params.msa_mount} - the instance predates the mount in its launch template" >&2
        exit 1
    fi

    # Which AZ this landed in decides whether the write crosses one. The
    # filesystem lives in a single subnet and the queue spans four, so this is
    # recorded rather than controlled.
    az=\$(curl -sf -H "X-aws-ec2-metadata-token: \$(curl -sfX PUT \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        http://169.254.169.254/latest/api/token)" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone || echo unknown)
    mkdir -p "${params.msa_db_dir}"

    export NIM_CACHE_PATH="${params.msa_db_dir}"
    export NGC_API_KEY=\$(/opt/aws-cli/bin/aws secretsmanager get-secret-value \\
        --secret-id "${params.ngc_api_key_secret}" \\
        --region "${params.ngc_api_key_region}" \\
        --query SecretString \\
        --output text)

    # Already-present databases are skipped, so a rerun after an interruption
    # resumes rather than starting the ~1.2 TB again.
    started=\$(date +%s)
    ( cd /opt/nim && env PYTHONPATH=/opt/nim python3 -c \\
        'from nimlib import nimutils; nimutils.download_models(nimutils.get_model_manifest())' )
    finished=\$(date +%s)
    unset NGC_API_KEY NVIDIA_API_KEY

    {
        echo "profile: ${params.msa_nim_profile}"
        echo "availability_zone: \${az} (filesystem is in us-east-1a)"
        echo "target: ${params.msa_db_dir}"
        echo "elapsed_seconds: \$(( finished - started ))"
        echo
        echo "## layout"
        find "${params.msa_db_dir}" -maxdepth 4 -type d | head -40
        echo
        echo "## sizes"
        du -sh "${params.msa_db_dir}"/* 2>/dev/null || true
        echo
        echo "## mmseqs2 index files, which colabfold_search also needs"
        find "${params.msa_db_dir}" -name '*.idx' | head -20
        echo
        echo "## database basenames"
        find "${params.msa_db_dir}" \\( -name 'uniref30*' -o -name 'colabfold_envdb*' \\) \\
            -maxdepth 6 | head -20
    } > download_report.txt

    cat download_report.txt
    """
}

workflow {
    DOWNLOAD_NIM_DATABASES()
}
