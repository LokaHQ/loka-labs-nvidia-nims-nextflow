# Container assets

Build context for every image we build ourselves and push to ECR
(`520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims`, one repo, one tag per tool).

| Directory | ECR tag | What it is |
|---|---|---|
| `openfold3_nim/` | `openfold3-nim` | OpenFold3 NIM plus PAE output |
| `rfdiffusion_seed_patch/` | `rfdiffusion-seed-patch-v3` | RFdiffusion with scoped, seedable RNGs |
| `proteinmpnn_seed_patch/` | `proteinmpnn-seed-patch-v2` | ProteinMPNN with a `-seed` flag |
| `nim_entrypoint_fix/` | `rfdiffusion`, `rfdiffusion-nim-updated`, `proteinmpnn-nim-updated` | Entrypoint cleared so Nextflow can run its own command |

Images pulled straight from NGC and re-tagged (`rfdiffusion-nim`, `proteinmpnn-nim`,
`msa-search`) have no Dockerfile — see `iac/README.md` for the pull/tag/push steps.

The seed-patch and entrypoint-fix Dockerfiles were reconstructed from `docker history`
on 2026-10-15, after the originals were lost with a scratch directory. The Python
sources beside them were extracted from the built images, so they are the exact code
that ran in the benchmark. Rebuilding from these should reproduce the images, but that
has not been verified against the pushed digests.

## Build and push

```bash
REGISTRY=520168724997.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$REGISTRY"

docker build --platform linux/amd64 \
  -t "$REGISTRY/nvidia-nims:rfdiffusion-seed-patch-v3" assets/rfdiffusion_seed_patch
docker push "$REGISTRY/nvidia-nims:rfdiffusion-seed-patch-v3"
```

The `nim_entrypoint_fix` Dockerfiles need `-f`, since they share one directory:

```bash
docker build --platform linux/amd64 -f assets/nim_entrypoint_fix/Dockerfile.rfdiffusion-nim \
  -t "$REGISTRY/nvidia-nims:rfdiffusion-nim-updated" assets/nim_entrypoint_fix
```

Base images are pinned by digest. The hosts are amd64, so `--platform linux/amd64`
matters when building from an Apple Silicon machine.
