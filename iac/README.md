# Protein design on AWS Batch — infrastructure

Infrastructure for running RFdiffusion → ProteinMPNN → AF2, with NVIDIA NIM and non-NIM variants
of each tool, on AWS Batch. CDK (TypeScript) provisions the infrastructure; job submission
(e.g. a Nextflow pipeline) is out of scope of this repo for now.

```
iac/                               # CDK app
├── src/
│   ├── main.ts                    # app entrypoint
│   ├── config.ts                  # every tunable value lives here
│   ├── stack.ts                   # NvidiaNimsStack — composes the constructs below
│   └── constructs/
│       ├── network.ts             # VPC, subnets, NAT, S3/ECR/Logs VPC endpoints
│       ├── storage.ts             # input + workdir + output buckets and their resource policies
│       ├── registry.ts            # one shared ECR repository for every tool image
│       └── batch.ts               # launch templates, compute environments, queues, IAM
└── test/                          # snapshot + guardrail tests
```

## What gets created

| Area | Resources |
|---|---|
| Networking | Dedicated VPC (`10.60.0.0/16`), public + private subnets across 2 AZs, NAT gateway, S3 **gateway** endpoint, **interface** endpoints for ECR API, ECR DKR and CloudWatch Logs |
| Storage | Input bucket (no versioning, 30-day expiry), workdir bucket for the pipeline's work directory (no versioning, 30-day expiry), and output bucket (versioned, no expiry). All SSE-S3, TLS-enforced, all public access blocked, `RETAIN` on delete, resource policy scoped to the pipeline roles |
| Registry | One shared repository (`nvidia-nims`), tools distinguished by tag (`rfdiffusion-*`, `proteinmpnn-nim-*`, `proteinmpnn-nonim-*`, `af2-nim-*`, `af2-nonim-*`), scan-on-push, untagged images expired after 14 days |
| Compute | 3 queues × (Spot CE + On-Demand CE) = 6 compute environments, 3 launch templates, `minvCpus: 0` and `BEST_FIT_PROGRESSIVE` everywhere |
| IAM | Container instance role (+ instance profile) and a job role that the bucket policies are scoped to |

No Batch **job definitions** are declared here: whatever submits jobs (e.g. Nextflow's `awsbatch`
executor) registers one per container image at run time. Declaring them here would just create
drift.

## Deploying

Pre-requisites: `node` >= 22, `yarn`, AWS credentials (`aws sts get-caller-identity`),
[`aws-vault`](https://github.com/ByteNess/aws-vault) recommended.

```
cd iac
yarn install
yarn bootstrap [aws://123456789012/us-east-1]   # once per account+region, ever
yarn diff                                        # review before the first deploy
yarn deploy
```

Both `yarn bootstrap` and `yarn deploy` already carry `--tags Project=nvidia-nims`
(`package.json`), and the stack targets **us-east-1** by default (`src/main.ts`) regardless of
`CDK_DEFAULT_REGION` in your shell.

> **Why `--tags` on every deploy.** Some resources CDK creates internally (e.g. the singleton
> Lambda behind `restrictDefaultSecurityGroup` in `network.ts`) are instantiated during synthesis,
> after the `Tags.of(stack).add(...)` Aspect in `stack.ts` has already run, so they never pick up
> that resource-level tag. `--tags` sets an actual CloudFormation **stack** tag instead, which
> CloudFormation propagates to every resource it creates — including those. If your org enforces
> an SCP requiring a `Project` tag on resource creation (`aws:RequestTag/Project`), omitting
> `--tags` here will fail with an SCP `AccessDenied` on that Lambda.

Other commands: `yarn synth`, `yarn test`, `yarn test:fix` (update snapshots), `yarn lint`,
`yarn fmt:fix`, `yarn compile`.

> **GPU quotas.** `L-3819A6DF` (*All G and VT Spot Instance Requests*) and `L-DB2E81BA`
> (*Running On-Demand G and VT instances*) both default to **0** in a fresh account, and p4d has
> its own pair. Request increases *before* deploying, or every GPU job sits in `RUNNABLE`
> forever with no error to explain why.

> **You will lock yourself out of the buckets.** `storage.restrictToJobRole` is on by default
> and denies `s3:*` to every principal except the job role, the instance role, the account root
> and the CDK deployment roles — so your own `aws s3 cp` of the input files will be denied too.
> Add whatever role humans use to `storage.additionalPrincipalArns` in `src/config.ts` (SSO
> roles take a wildcard: `arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/*`), or set
> `restrictToJobRole: false` if identity-based policies are enough for your account.

Stack outputs (bucket names, queue names, job role ARN, ECR registry/repository) are what
whatever submits jobs will need:

```
aws cloudformation describe-stacks --stack-name NvidiaNimsBatch \
  --query 'Stacks[0].Outputs' --output table
```

## Building and pushing the images

Every tool shares the one `nvidia-nims` repository, distinguished by a `<tool>-<version>` tag.
For the NIM images, pull from NGC and re-tag; for the non-NIM ones, build your own.

```
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# NIM images: pull from NGC (needs an NGC API key), re-tag, push.
docker login nvcr.io --username '$oauthtoken' --password "$NGC_API_KEY"
docker pull nvcr.io/nim/ipd/rfdiffusion:<version>
docker tag  nvcr.io/nim/ipd/rfdiffusion:<version> "$REGISTRY/nvidia-nims:rfdiffusion-<version>"
docker push "$REGISTRY/nvidia-nims:rfdiffusion-<version>"

# non-NIM images: build from your own Dockerfile.
docker build -t "$REGISTRY/nvidia-nims:proteinmpnn-nonim-<version>" ./containers/proteinmpnn
docker push "$REGISTRY/nvidia-nims:proteinmpnn-nonim-<version>"
```

Repeat for `proteinmpnn-nim`, `af2-nim` and `af2-nonim`. Pin whatever tag or digest you push to a
real value before wiring it into a job — don't leave it on `latest`.

## How queue routing works

A process declares a **label**; the label maps to a **queue**; the queue is backed by hardware
that fits. Nothing else routes.

| Label | Queue | Instance types | Volume | Processes |
|---|---|---|---|---|
| `cpu_small` | `nvidia-nims-cpu-small` | m5/c5 `.large`–`.2xlarge` | 100 GiB | ProteinMPNN no-NIM (1 CPU, 4 GB, no GPU) |
| `gpu_standard` | `nvidia-nims-gpu-standard` | g6e `.2xlarge`–`.8xlarge` | 200 GiB | RFdiffusion, ProteinMPNN NIM, AF2 no-NIM |
| `gpu_highmem` | `nvidia-nims-gpu-highmem` | g6e.12xlarge, p4d.24xlarge | 1400 GiB | AF2 NIM (64 GB RAM, 1250 GB disk) |

The label sets the queue and a baseline request; whatever submits the job pins each tool's exact
cpus/memory/disk on top of that. Batch then packs jobs onto instances by those requests, so two
ProteinMPNN NIM jobs can share a host while one AF2 NIM job gets a machine to itself.

**Spot with On-Demand fallback** is a queue-level construct, not a compute-environment one: a
Batch compute environment is either Spot or On-Demand, never both. Each queue therefore lists
its Spot CE at order 1 and its On-Demand CE at order 2, and Batch only reaches for order 2 when
Spot cannot place the job. Set `onDemandMaxvCpus: 0` for a queue that should wait for Spot
rather than pay full price.


### Cost notes

Spot is ~50% cheaper than On-Demand across the board, and the margin is too wide for
interruptions to reverse it, but the single largest cost decision is whether AF2 NIM's 1.25 TB of
databases are shared across tasks or materialised per task — that alone is a 4× swing on the
dominant job.

- `minvCpus: 0` on all six compute environments: idle costs nothing, at the price of a
  cold-start (instance launch + image pull) on the first job of a burst.
- The VPC endpoints exist to keep image pulls and log traffic off the NAT gateway's per-GB
  meter. With 20–40 GB NIM images this is the single largest cost decision in the stack.
- `BEST_FIT_PROGRESSIVE` is used on the Spot CEs as specified. If Spot interruptions become the
  bottleneck rather than cost, `SPOT_PRICE_CAPACITY_OPTIMIZED` picks from the deepest capacity
  pools and is usually the better default — it's one line in `src/constructs/batch.ts`.
- `disk` directives are advisory on AWS Batch: Batch has no disk resource requirement, so actual
  capacity comes from the queue's launch template volume, not from the process directive.

## Tests

`yarn test` runs a CloudFormation snapshot plus guardrails that are cheap to assert and
expensive to get wrong: the input bucket expires and the output bucket doesn't, both stay
private/encrypted/retained and carry the deny-everyone-else policy, one scan-on-push repository
shared by every tool, three queues each with a Spot→On-Demand fallback pair, `minvCpus: 0` and
`BEST_FIT_PROGRESSIVE` on all six CEs, the NVIDIA AMI on exactly the GPU environments, only
gpu-highmem carrying the 1.4 TB volume, and S3/ECR keeping their VPC endpoints.

`test/__snapshots__/subnet-cidrs.json` pins subnet CIDRs to their logical IDs and fails loudly
on a replacement.
