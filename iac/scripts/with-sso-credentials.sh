#!/bin/bash
# Run a cdk command with credentials from an SSO profile.
#
# CDK does not resolve SSO profiles through AWS_PROFILE the way the CLI does, so
# it reports "no credentials have been configured" against a logged-in session.
# Exporting them into the environment first is the simplest fix that does not
# require aws-vault.
#
# Usage: scripts/with-sso-credentials.sh deploy [cdk args...]
#        AWS_PROFILE=other-profile scripts/with-sso-credentials.sh diff
set -euo pipefail

profile="${AWS_PROFILE:-lokalabs-nims}"

if ! credentials=$(AWS_PROFILE="${profile}" aws configure export-credentials --format env 2>&1); then
    echo "Could not read credentials for profile '${profile}'." >&2
    echo "Log in first:  aws sso login --profile ${profile}" >&2
    exit 1
fi
eval "${credentials}"

export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}"
export CDK_DEFAULT_REGION="${CDK_DEFAULT_REGION:-us-east-1}"

exec yarn "$@"
