# Weight-cached NIM images

Each NIM task currently re-downloads its model weights from NGC, inside the
window that `NIM_BOOT_SECONDS` measures. Across the N=150 run that was about
2.3 TB and $101.97 of NAT gateway charges. None of the three NIM modules sets
`NIM_CACHE_PATH`, so every container starts with an empty cache.

These images carry the weights, so `start_server.sh` finds them present.

## Tags

| new tag | built FROM | never touched |
|---|---|---|
| `rfdiffusion-nim-cached` | `rfdiffusion-nim` | yes |
| `proteinmpnn-nim-cached` | `proteinmpnn-nim` | yes |
| `openfold3-nim-cached` | `openfold3-nim` | yes |

Each cached image is built from the exact tag that ran the N=150 benchmark, so
the weight cache is the only difference. `build.sh` refuses to build over any
of the protected tags.

## Two steps, two machines

**1. `populate-cache.sh` — must run on linux/amd64.**

Starts each NIM once and lets it download its own weights into `cache/<nim>-nim`.
This deliberately uses the same code path the pipeline runs rather than guessing
at an internal download command.

It cannot run on an Apple Silicon Mac: the NIMs are amd64 CUDA images.

Whether it also needs a GPU is **not yet established**. The server needs CUDA to
reach `/v1/health/ready`, but the download may well finish before that matters,
and the script keeps whatever landed in the cache even if the server never
answered. So try the cheap option first:

```bash
# CPU-only amd64 box, ~$0.38/h
GPU_FLAG= ./populate-cache.sh rfdiffusion
```

If the cache comes back populated, no GPU is needed for any of them. If it
comes back empty, check `cache/rfdiffusion-nim.populate.log` and rerun on a
`g6e.4xlarge` with the default `GPU_FLAG`.

**2. `build.sh` — runs anywhere, including the Mac.**

Only adds `COPY` and `ENV` layers, so buildx emulation is fine and fast.

```bash
PUSH=0 ./build.sh     # build and verify locally
./build.sh            # build, verify, push
```

## Using them

Point the NIM profile at the new tags, e.g.

```
--rfd_container_tag rfdiffusion-nim-cached
```

`conf/platforms/aws_batch_nims.config` takes `openfold3_nim_image` directly;
the other two are hard-coded and would need a parameter adding.

## What this does not fix

The server still boots on every task — this removes the download, not the
start. ProteinMPNN boots in 5.1 s with almost nothing to fetch, which is
roughly the floor. Batching is the other half of the fix and is already
implemented.
