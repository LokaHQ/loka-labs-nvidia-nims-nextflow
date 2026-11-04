# nf-binder-design

[![DOI](https://zenodo.org/badge/921968505.svg)](https://doi.org/10.5281/zenodo.16809704) | [![Documentation](https://img.shields.io/badge/docs-online-blue)](https://australian-protein-design-initiative.github.io/nf-binder-design/)

Nextflow pipelines for _de novo_ protein binder design.

![RFdiffusion workflow](docs/docs/images/rfd-workflow.png)

- RFdiffusion → ProteinMPNN → AlphaFold2 initial guess → Boltz-2 refolding
- RFdiffusion3 → MPNN → RosettaFold3 → Boltz-2 refolding
- RFdiffusion Partial Diffusion → Boltz-2 refolding
- BindCraft (in parallel across multiple GPUs)
- Germinal (antibody/nanobody design in parallel across multiple GPUs)
- BoltzGen (design proteins and peptides binders, in parallel across multiple GPUs)
- "Boltz Pulldown" (an AlphaPulldown-like protocol using Boltz-2)

----

> ⚠️ Note: Components of these workflows use RFdiffusion and BindCraft, which depend on PyRosetta/Rosetta, which is free for non-commercial use. Commercial use requires a paid license agreement with University of Washington: https://github.com/RosettaCommons/rosetta/blob/main/LICENSE.md and https://rosettacommons.org/software/licensing-faq/

----

> ⚠️ NOTE: Major change in `v0.2.0` - individual workflows have been shifted into `workflows/`, all launched via a single `main.nf` entry point with the `--method` flag. 
>          To modify any existing wrapper scripts, you should be able to simply use `nextflow run Australian-Protein-Design-Initiative/nf-binder-design --method <method>`.
>          and keep other arguments the same. ⚠️

----

## This fork: NVIDIA NIM vs open-source benchmark

Loka's fork of [nf-binder-design](https://github.com/Australian-Protein-Design-Initiative/nf-binder-design),
used to benchmark NVIDIA NIM containers against the equivalent open-source
containers on AWS Batch. Everything upstream still works; this section covers
only what is specific to the benchmark.

### The two arms

| arm | `--method` | profile | RFdiffusion | ProteinMPNN | folding |
|---|---|---|---|---|---|
| open source | `rfd_openfold` | `aws_batch_openfold` | upstream image | upstream | OpenFold3 (pixi build) |
| NIM | `rfd_nim` | `aws_batch_nims` | RFdiffusion NIM | ProteinMPNN NIM | OpenFold3 NIM |

Both arms share the MSA, threading/relax and BindCraft scoring steps, so a
difference between them is a difference in the three model containers.

### Prerequisites

1. **AWS credentials.** `aws sso login --profile lokalabs-nims`. Account
   520168724997, `us-east-1`.
2. **NGC API key in Secrets Manager** under `nvidia-nims/ngc-api-key`, as a
   personal key (`nvapi-…`). The NIM tasks read it at runtime; a service key
   will not authenticate.
3. **Container images in ECR** (`520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims`).
   See `assets/` for how each was built.
4. **Batch compute environments enabled.** They are left `DISABLED` between
   runs so nothing can accrue cost; the run scripts enable them on start and
   disable them again on exit, including on failure.

### Running the benchmark

```bash
cd examples/pdl1-rfd
./run-n150.sh          # both arms, 150 designs each, ~3 h
```

Or one arm directly:

```bash
nextflow run main.nf --method rfd_nim \
  --input_pdb input/PDL1.pdb \
  --contigs "[A18-132/0 78-78]" \
  --hotspot_res A56,A63,A113,A123,A124 \
  --rfd_n_designs 150 --rfd_seeds "$(seq -s, 0 149)" \
  --msa_target_a3m assets/msa/pdl1_target.a3m \
  --outdir s3://nvidia-nims-output/my-run \
  -profile aws_batch_nims -with-trace
```

Pass the same `--rfd_seeds` to both arms. RFdiffusion is deterministic across
the two implementations, so matched seeds give bit-identical backbones and the
comparison becomes paired rather than two independent groups.

### Options specific to this fork

| option | default | what it does |
|---|---|---|
| `--of3_batch_size` | 1 | designs served per OpenFold3 NIM server boot |
| `--rfd_batch_size` | 1 | designs per RFdiffusion NIM server boot |
| `--rfd_nim_container_tag` | `rfdiffusion-nim` | set to `rfdiffusion-nim-cached` for the weight-cached image |
| `--pmpnn_nim_container_tag` | `proteinmpnn-nim` | set to `proteinmpnn-nim-cached` likewise |
| `--openfold3_nim_image` | *(unset)* | full image reference, overrides the default tag |
| `--rfd_standalone` | false | open-source arm uses the same RFdiffusion the NIM wraps |

**Batch size is the lever that matters.** Each NIM task boots an HTTP server
before it infers, and at one design per container that boot dominates. See
`benchmarks/` for the measured figures.

### Cost

Both profiles use Spot by default. Guardrails exist in the account: a $40/day
and a $250/month budget, both measured on gross usage with credits excluded,
and CloudWatch alarms on NAT gateway throughput. Check them before a long run:

```bash
aws budgets describe-budgets --account-id 520168724997 --profile lokalabs-nims
aws cloudwatch describe-alarms --alarm-name-prefix nims- --profile lokalabs-nims
```

Container execution is only part of the bill. Model weights and any image not
held in ECR are pulled over the NAT gateway, which on the N=150 run cost more
than the compute did. `assets/nim_weight_cache/` builds images with the weights
already inside to avoid the repeated download.

### Results

`benchmarks/` holds the findings documents and `benchmarks/scripts/` the
analysis that produced them.

----

## Documentation

----

**Full documentation at:** https://australian-protein-design-initiative.github.io/nf-binder-design/

The experimental [local OpenFold3](docs/docs/workflows/rfd-openfold.md) and [RFdiffusion NIM](docs/docs/workflows/rfd-nim.md) workflows provide comparable RFdiffusion → ProteinMPNN/Rosetta → OpenFold3 → BindCraft paths.

An [agent skill](.agents/skills/nf-binder-design/SKILL.md) is included for AI-assisted setup, configuration, and execution of the pipeline workflows.

----

## Quickstart

### Setup

Install [Nextflow](https://www.nextflow.io/docs/latest/install.html).

Pull the workflow:

```bash
nextflow pull Australian-Protein-Design-Initiative/nf-binder-design
```

### AI Agent Skill

An agent skill is included at [`.agents/skills/nf-binder-design/`](.agents/skills/nf-binder-design/SKILL.md) to help AI coding agents set up, configure, and run the pipeline. Install it into your project with [skills](https://github.com/vercel-labs/skills):

```bash
npx skills add Australian-Protein-Design-Initiative/nf-binder-design --skill nf-binder-design
```

### Running on a local GPU workstation

A minimal RFdiffusion binder design run against the PD-L1 example target (requires a local GPU and [Apptainer](https://apptainer.org/)):

```bash
# Make a working directory and download a target PDB
mkdir -p pdl1-rfd/input
cd pdl1-rfd
wget -O input/PDL1.pdb https://raw.githubusercontent.com/Australian-Protein-Design-Initiative/nf-binder-design/refs/heads/main/examples/pdl1-rfd/input/PDL1.pdb

# Run the workflow
nextflow run Australian-Protein-Design-Initiative/nf-binder-design \
  --method rfd \
  --input_pdb 'input/*.pdb' \
  --contigs "[A18-132/0 65-120]" \
  --hotspot_res "A56" \
  --rfd_n_designs=4 \
  -profile local \
  -resume
```

### Running on an HPC cluster

```bash
mkdir -p pdl1-rfd/input
cd pdl1-rfd
wget -O input/PDL1.pdb https://raw.githubusercontent.com/Australian-Protein-Design-Initiative/nf-binder-design/refs/heads/main/examples/pdl1-rfd/input/PDL1.pdb

nextflow run Australian-Protein-Design-Initiative/nf-binder-design \
  --method rfd \
  --input_pdb 'input/*.pdb' \
  --contigs "[A18-132/0 65-120]" \
  --hotspot_res "A56" \
  --rfd_n_designs=4 \
  -profile slurm \
  -resume
```

> You'll almost certainly need to create a custom configuration file for your HPC cluster. See `conf/platforms/` for specific HPC platform configuration examples, eg `-profile slurm,m3`.

### Commandline options

For any workflow, list available options with `--help`:

```bash
nextflow run Australian-Protein-Design-Initiative/nf-binder-design \
  --method rfd --help
```

Available methods: `rfd`, `rfd_openfold` (experimental local OpenFold3 workflow), `rfd_nim` (experimental AWS NIM workflow), `rfd3`, `rfd_partial`, `bindcraft`, `germinal`, `boltzgen`, `boltz_pulldown`, `foldseek`

Any `--params` option can alternatively be defined in a `params.json` file and passed with `-params-file params.json`.

For running tests and other contributor notes, see [Development](https://australian-protein-design-initiative.github.io/nf-binder-design/extra/development/).

## More examples

See the [examples](examples/) directory and [workflow documentation](https://australian-protein-design-initiative.github.io/nf-binder-design/) for other methods (including Germinal), HPC configs, and production-scale runs.

## License

MIT

> Note that some software dependencies of the pipeline are under less permissive licenses - in particular, RFdiffusion and BindCraft use [Rosetta/PyRosetta](https://github.com/RosettaCommons/rosetta/blob/main/LICENSE.md) which is **only free for Non-Commercial use**.
