# Upstream Dockerfiles (reference copies)

Not ours and not built here. These are the recipes behind the base images our own
Dockerfiles sit on top of, vendored so the full build chain is readable in one place.

Fetched 2026-10-15 from `Australian-Protein-Design-Initiative/containers`
at commit `7ec42f2`:

| File | Builds | Our ECR tag |
|---|---|---|
| `Dockerfile.rfdiffusion-pytorch2407` | `rfdiffusion:pytorch2407` | `rfdiffusion` (entrypoint cleared) |
| `Dockerfile.proteinmpnn_dl_binder_design` | `proteinmpnn_dl_binder_design:latest` | `proteinmpnn` (unmodified copy) |

To change these, send a PR upstream — editing the copies here does nothing.

## Reproducibility of the sources

ProteinMPNN pins both checkouts (`DLBINDER_COMMIT=cafa385`,
`PROTEINMPNN_COMMIT=8907e66`), so rebuilding gets the same code.

RFdiffusion does not: it clones `RosettaCommons/RFdiffusion` at whatever `main`
points to. Rebuilding from this file today would not reproduce the image we run —
that one was built 2026-09-22 and is pinned only by its ECR digest
(`sha256:4f554a1c…`). Treat the digest as the source of truth, not this Dockerfile.
