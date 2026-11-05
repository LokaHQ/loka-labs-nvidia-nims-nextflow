#!/bin/bash
#
# Disable every Batch compute environment AND terminate the instances they
# already launched.
#
# Disabling a compute environment only stops it launching new instances. Any
# instance already up keeps running, and keeps billing, until Batch scales it
# down on its own schedule - which it will not do promptly once the queue is
# empty. A GPU instance left this way costs about $2.24/hour. Every run must
# end by calling this, on success and on failure alike.
#
# Instances are found through each compute environment's own ECS cluster
# rather than by tag, so nothing outside Batch can be caught by mistake.
set -uo pipefail

PROFILE="${AWS_PROFILE:-lokalabs-nims}"
REGION="${AWS_REGION:-us-east-1}"
AWS=(aws --profile "${PROFILE}" --region "${REGION}")

batch_instance_ids() {
    local cluster id
    for cluster in $("${AWS[@]}" batch describe-compute-environments \
            --query 'computeEnvironments[].ecsClusterArn' --output text); do
        for id in $("${AWS[@]}" ecs list-container-instances \
                --cluster "${cluster}" --query 'containerInstanceArns' \
                --output text 2>/dev/null); do
            [ "${id}" = "None" ] && continue
            "${AWS[@]}" ecs describe-container-instances \
                --cluster "${cluster}" --container-instances "${id}" \
                --query 'containerInstances[].ec2InstanceId' --output text 2>/dev/null
        done
    done
}

echo "=== disabling all compute environments ==="
for ce in $("${AWS[@]}" batch describe-compute-environments \
        --query 'computeEnvironments[].computeEnvironmentName' --output text); do
    "${AWS[@]}" batch update-compute-environment \
        --compute-environment "${ce}" --state DISABLED >/dev/null 2>&1 \
        && echo "DISABLED ${ce}"
done

echo "=== terminating Batch-launched instances ==="
ids=$(batch_instance_ids | tr '\n' ' ')
if [ -z "${ids// /}" ]; then
    echo "none registered"
else
    # shellcheck disable=SC2086
    "${AWS[@]}" ec2 terminate-instances --instance-ids ${ids} \
        --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
fi

# Belt and braces: an instance that booted but never registered with ECS would
# be missed above, so check the compute environments report no capacity either.
echo "=== verifying ==="
for i in $(seq 1 30); do
    left=$(batch_instance_ids | grep -c . || true)
    desired=$("${AWS[@]}" batch describe-compute-environments \
        --query 'sum(computeEnvironments[].computeResources.desiredvCpus)' --output text)
    if [ "${left}" = "0" ] && [ "${desired}" = "0" ]; then
        echo "all clear: 0 Batch instances, 0 desired vCPUs"
        exit 0
    fi
    echo "  ${left} instance(s), ${desired} desired vCPUs still winding down (${i}/30)..."
    sleep 10
done

echo "WARNING: Batch capacity is still up - check the console" >&2
exit 1
