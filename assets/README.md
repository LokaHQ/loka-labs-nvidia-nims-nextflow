# Container assets

Build context for every image we build ourselves and push to ECR
(`520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims`, one repo, one tag per tool).

| Directory | ECR tag | What it is |
|---|---|---|
| `openfold3_nim/` | `openfold3-nim` | OpenFold3 NIM plus PAE output |
| `rfdiffusion_seed_patch/` | `rfdiffusion-seed-patch-v3` | RFdiffusion with scoped, seedable RNGs |
| `proteinmpnn_seed_patch/` | `proteinmpnn-seed-patch-v2` | ProteinMPNN with a `-seed` flag |
| `nim_entrypoint_fix/` | `rfdiffusion`, `rfdiffusion-nim-updated`, `proteinmpnn-nim-updated` | Entrypoint cleared so Nextflow can run its own command |

## Provenance of every tag in use

Each tag the pipeline references, and where it came from. Tags marked *re-tag* are
unmodified copies of an upstream image — we never built them, so there is no
Dockerfile to keep; `iac/README.md` has the pull/tag/push steps.

Built by us:

| ECR tag | Source | Build context | ECR digest | Pushed |
|---|---|---|---|---|
| `rfdiffusion` | `ghcr.io/…/rfdiffusion:pytorch2407`, entrypoint cleared | `nim_entrypoint_fix/Dockerfile.rfdiffusion` | `sha256:4f554a1c…` | 2026-09-22 |
| `rfdiffusion-nim` | `nvcr.io/nim/ipd/rfdiffusion:2.3.0`, entrypoint cleared | `nim_entrypoint_fix/Dockerfile.rfdiffusion-nim` | `sha256:acf05a7f…` | 2026-09-24 |
| `proteinmpnn-nim` | `nvcr.io/nim/ipd/proteinmpnn:1.2.0`, entrypoint cleared | `nim_entrypoint_fix/Dockerfile.proteinmpnn-nim` | `sha256:2368d886…` | 2026-09-24 |
| `openfold3-nim` | `nvcr.io/nim/openfold/openfold3`, PAE output added | `openfold3_nim/Dockerfile` | `sha256:4a3b5acb…` | 2026-09-30 |
| `rfdiffusion-seed-patch-v3` | `:rfdiffusion` plus scoped RNGs | `rfdiffusion_seed_patch/Dockerfile` | `sha256:871f9618…` | 2026-10-07 |
| `proteinmpnn-seed-patch-v2` | `:proteinmpnn` plus a `-seed` flag | `proteinmpnn_seed_patch/Dockerfile` | `sha256:045e81d8…` | 2026-10-13 |

Unmodified copies of an upstream image — we never built these. The upstream
recipes for the two APDI ones are vendored in `upstream/` for reference. `iac/README.md` has the pull/tag/push steps.

| ECR tag | Upstream source | ECR digest | Pushed |
|---|---|---|---|
| `proteinmpnn` | `ghcr.io/…/proteinmpnn_dl_binder_design:latest` | `sha256:149b07db…` | 2026-09-21 |
| `af2-initial-guess` | `ghcr.io/…/af2_initial_guess:nv-cuda12` | `sha256:e5be4428…` | 2026-09-21 |
| `bindcraft` | `ghcr.io/…/bindcraft:nv-cuda120` | `sha256:1c7a98bf…` | 2026-09-21 |
| `nf-binder-design-utils` | `ghcr.io/…/nf-binder-design-utils:0.1.6` | `sha256:b00bfa46…` | 2026-09-21 |
| `openfold3-v0.5-pixi` | `openfoldconsortium/openfold3:0.5-pixi` | `sha256:8764f732…` | 2026-09-30 |
| `msa-search` | `nvcr.io/nim/colabfold/msa-search:latest` | `sha256:944f3cf8…` | 2026-10-07 |

Tags and digests verified against ECR on 2026-10-15. Two things worth knowing:

- The `rfdiffusion-nim` and `proteinmpnn-nim` tags hold our entrypoint-cleared
  builds, not the stock NIMs — the modified images were pushed over those tags,
  and the unmodified NIMs were never pushed. Rebuilding them needs an NGC key.
- `rfdiffusion-seed-patch-v3` is in ECR but no config references it.

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
