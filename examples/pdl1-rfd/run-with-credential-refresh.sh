#!/bin/bash
#
# Run a Nextflow pipeline, resuming it whenever AWS credentials expire.
#
# SSO gives an assumed-role token good for about an hour, and Nextflow reads
# credentials once at launch rather than refreshing them. A run longer than
# that dies with "Signature expired ... Status Code: 403" and aborts, however
# healthy the pipeline is. This re-exports fresh credentials from the still
# valid SSO session and resumes, so completed tasks are not repeated.
#
# It stops when the SSO session itself expires (typically 8 hours), because
# only a browser login can renew that.
#
#   ./run-with-credential-refresh.sh <log-file> <nextflow args...>
set -uo pipefail

LOG_FILE="${1:?usage: run-with-credential-refresh.sh <log-file> <nextflow args...>}"
shift

PROFILE="${AWS_PROFILE:-lokalabs-nims}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-12}"

export NXF_SYNTAX_PARSER=v1

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
    if ! credentials=$(AWS_PROFILE="${PROFILE}" aws configure export-credentials --format env 2>&1); then
        echo "=== attempt ${attempt}: SSO session is gone, needs 'aws sso login --profile ${PROFILE}'" | tee -a "${LOG_FILE}"
        exit 2
    fi
    eval "${credentials}"

    # -resume only from the second attempt: the first may be a fresh run.
    resume_flag=""
    [ "${attempt}" -gt 1 ] && resume_flag="-resume"

    echo "=== attempt ${attempt} at $(date -u +%H:%M:%SZ) ${resume_flag}" | tee -a "${LOG_FILE}"
    nextflow run "$@" ${resume_flag} >>"${LOG_FILE}" 2>&1
    status=$?

    if [ "${status}" -eq 0 ]; then
        echo "=== finished cleanly on attempt ${attempt}" | tee -a "${LOG_FILE}"
        exit 0
    fi

    # Only a credential expiry is worth retrying blindly. Anything else is a
    # real failure and repeating it just burns GPU time.
    #
    # Look in .nextflow.log, not just stdout: an expiry surfaces there as
    # "Session aborted -- Cause: ... token ... expired", while stdout shows
    # only the downstream symptom (a failed S3 write in the onComplete
    # handler). Grepping stdout alone misreads an expiry as a real failure.
    credential_error="Signature expired|ExpiredToken|security token included in the request is|Token has expired"
    if ! { tail -40 "${LOG_FILE}"; tail -200 .nextflow.log 2>/dev/null; } \
            | grep -qE "${credential_error}"; then
        echo "=== attempt ${attempt} failed for a reason other than credentials - stopping" | tee -a "${LOG_FILE}"
        exit "${status}"
    fi
    echo "=== attempt ${attempt} died on expired credentials, refreshing and resuming" | tee -a "${LOG_FILE}"
done

echo "=== gave up after ${MAX_ATTEMPTS} attempts" | tee -a "${LOG_FILE}"
exit 1
