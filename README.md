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
every way the pipeline can be run here.

### Methods

One entry point, `main.nf`, selected with `--method`.

| `--method` | workflow | what it does |
|---|---|---|
| `rfd` | `workflows/rfd.nf` | RFdiffusion to ProteinMPNN to AlphaFold2 initial guess |
| `rfd_openfold` | `workflows/rfd_openfold.nf` | **no-NIM benchmark arm** - open-source containers throughout, OpenFold3 for folding |
| `rfd_nim` | `workflows/rfd_nim.nf` | **NIM benchmark arm** - RFdiffusion, ProteinMPNN and OpenFold3 as NIM servers |
| `rfd_partial` | `workflows/rfd_partial.nf` | partial diffusion from an existing backbone |
| `rfd3` | `workflows/rfd3.nf` | RFdiffusion3 to MPNN to RosettaFold3 |
| `bindcraft` | `workflows/bindcraft.nf` | BindCraft design |
| `germinal` | `workflows/germinal.nf` | antibody and nanobody design |
| `boltzgen` | `workflows/boltzgen.nf` | BoltzGen protein and peptide binders |
| `boltz_pulldown` | `workflows/boltz_pulldown.nf` | AlphaPulldown-like protocol using Boltz-2 |
| `foldseek` | `workflows/foldseek.nf` | structure search |

Only `rfd_openfold` and `rfd_nim` are part of the benchmark. The rest are
upstream and unchanged.

### Profiles

```
-profile <name>
```

| profile | config | for |
|---|---|---|
| `local` | — | a single workstation with a GPU |
| `slurm` | — | generic SLURM cluster |
| `hq` / `hyperqueue` | `conf/platforms/hyperqueue.config` | HyperQueue |
| `aws_batch` | `conf/platforms/aws_batch.config` | AWS Batch, upstream containers |
| `aws_batch_openfold` | `conf/platforms/aws_batch_openfold.config` | **AWS Batch, no-NIM arm** |
| `aws_batch_nims` | `conf/platforms/aws_batch_nims.config` | **AWS Batch, NIM arm** |
| `m3` / `m3_bdi` | `conf/platforms/m3.config`, `m3_bdi.config` | Monash M3 |
| `mlerp` | `conf/platforms/mlerp.config` | MLeRP |
| `rotibom_hyperqueue` | `conf/platforms/rotibom_hyperqueue.config` | Rotibom |

Other site configs exist in `conf/platforms/` without a matching profile and
are included with `-c`: `monash_containers.config`, `nci_gadi.config`,
`pawsey_setonix.config`, `spartan.config`, `spartan-a100.config`,
`spartan-l40s.config`.

### The two benchmark arms

| | no-NIM | NIM |
|---|---|---|
| method / profile | `rfd_openfold` / `aws_batch_openfold` | `rfd_nim` / `aws_batch_nims` |
| RFdiffusion | upstream image, or the NIM-packaged model with `--rfd_standalone true` | RFdiffusion NIM |
| ProteinMPNN | `dl_binder_design` | ProteinMPNN NIM |
| folding | OpenFold3, pixi build | OpenFold3 NIM |
| MSA, threading/relax, BindCraft | identical in both arms | identical in both arms |

Pass the same `--rfd_seeds` to both. RFdiffusion is deterministic across the
two implementations, so matched seeds give bit-identical backbones and the
comparison is paired rather than two independent groups.

> ProteinMPNN does **not** honour a shared seed across the two
> implementations. From that step the arms design different sequences, so
> quality differences are pipeline-against-pipeline, not model-against-model.
> Timing is unaffected.

### Batching: one design per container, or many

Each NIM task boots an HTTP server before it infers. At one design per
container that boot dominates; batching amortises it across the designs in
the task.

| option | default | applies to |
|---|---|---|
| `--of3_batch_size` | 1 | designs per OpenFold3 NIM server boot (`rfd_nim`) |
| `--rfd_batch_size` | 1 | designs per RFdiffusion task (`rfd`, `rfd_nim`); 10 in `rfd_partial` |
| `--bindcraft_batch_size` | 1 | trajectories per BindCraft task |
| `--germinal_batch_size` | 1 | trajectories per Germinal task |
| `--rfd3_batch_size` | 1 | designs per RFdiffusion3 diffusion batch |
| `--rf3_batch_size` | 1 | MPNN designs per RosettaFold3 fold task |
| `--rf3_diffusion_batch_size` | 5 | RF3 CLI diffusion batch |
| `--batch_size` | 10 | BoltzGen |

No batching (the N=150 benchmark, one design per container):

```bash
--of3_batch_size=1 --rfd_batch_size=1
```

Batched:

```bash
--of3_batch_size=15 --rfd_batch_size=15
```

Batching changes timing only - each design is still a separate request with
its own seed.

### Container images

All images live in ECR at
`520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims`. The recipes are in
`assets/`.

| option | default | alternative |
|---|---|---|
| `--rfd_nim_container_tag` | `rfdiffusion-nim` | `rfdiffusion-nim-cached` |
| `--pmpnn_nim_container_tag` | `proteinmpnn-nim` | `proteinmpnn-nim-cached` |
| `--openfold3_nim_image` | *(unset, uses `openfold3-nim`)* | full image reference |
| `--pmpnn_container_tag` | — | open-source arm's ProteinMPNN, e.g. `proteinmpnn-seed-patch-v2` |
| `--rfd_container_tag` | — | open-source arm's RFdiffusion, e.g. `rfdiffusion-fixed` |

The `*-cached` tags carry the NGC model weights inside the image, so the
server finds them present instead of downloading them on every task. Built by
`assets/nim_weight_cache/`. They save transfer cost rather than time: the
download is roughly 5 s of a 97 s boot.

### Prerequisites for the AWS profiles

1. `aws sso login --profile lokalabs-nims` - account 520168724997, `us-east-1`.
2. An NGC **personal** key (`nvapi-...`) in Secrets Manager under
   `nvidia-nims/ngc-api-key`. A service key will not authenticate.
3. Batch compute environments are left `DISABLED` between runs so nothing can
   accrue cost. The run scripts enable them on start and disable them again on
   exit, including on failure.

### Example run scripts

In `examples/pdl1-rfd/`:

| script | runs |
|---|---|
| `run-n150.sh` | both benchmark arms, 150 designs each, matched seeds |
| `run-benchmark.sh` | the earlier benchmark harness |
| `run-aws-batch-nims.sh` | NIM arm only |
| `run-aws-batch-openfold-comparison.sh` | no-NIM arm only |
| `run-aws-batch.sh` | upstream `rfd` method on Batch |
| `run-local-simple.sh`, `run-local-full.sh`, `run-local-full-dual-gpu.sh`, `run-dual-gpu.sh` | local GPU workstation |
| `run-m3-full.sh` | Monash M3 |
| `run-with-credential-refresh.sh` | wrapper that renews SSO credentials during a long run |

Running one arm by hand:

```bash
nextflow run main.nf --method rfd_nim \
  --input_pdb input/PDL1.pdb \
  --contigs "[A18-132/0 78-78]" \
  --hotspot_res A56,A63,A113,A123,A124 \
  --rfd_n_designs 150 --rfd_seeds "$(seq -s, 0 149)" \
  --msa_target_a3m assets/msa/pdl1_target.a3m \
  --of3_batch_size 1 \
  --outdir s3://nvidia-nims-output/my-run \
  -profile aws_batch_nims -with-trace
```

### Cost

Both AWS profiles use Spot by default. Guardrails in the account: a $40/day
and a $250/month budget, both on gross usage with credits excluded, plus
CloudWatch alarms on NAT gateway throughput.

```bash
aws budgets describe-budgets --account-id 520168724997 --profile lokalabs-nims
aws cloudwatch describe-alarms --alarm-name-prefix nims- --profile lokalabs-nims
```

Container execution is only part of the bill. Model weights, and any image not
held in ECR, are pulled over the NAT gateway - on the N=150 run that cost more
than the compute did.

### Results

`benchmarks/` holds the findings documents; `benchmarks/scripts/` holds the
analysis that produced the published figures.

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
