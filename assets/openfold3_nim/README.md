# OpenFold3 NIM confidence response extension

The stock OpenFold3 1.5 NIM computes genuine PAE but drops its matrix when creating
the HTTP response. This image adds the existing PAE matrix and unrounded atom
pLDDT to each `outputs[].structures_with_scores[]` entry for PDB requests. It does
not change weights, model execution, sample selection, scores, coordinates, or
PDB formatting. CIF responses retain their existing contents.

Build from the repository root:

```bash
docker build --platform linux/amd64 -f assets/openfold3_nim/Dockerfile \
  -t openfold3-nim-pae:1.5 .
```

The base is pinned to the inspected OpenFold3 1.5 image digest
`sha256:6286cc7c02247ed3efe42f0f1af6c2f6f6a680b1e5cae669512c44b636aa42d2`.
The same digest was present under the project's `nvidia-nims:openfold3-nim` ECR
tag during inspection. The build verifies SHA256 hashes of both files it patches
and fails if the upstream implementation differs. The cleared entrypoint lets
AWS Batch run Nextflow's task command. Both the entrypoint and inherited default
command are empty; manual server startup requires an explicit command such as
`bash /opt/nim/start_server.sh`.

Publish the patched image under the existing `openfold3-nim` ECR tag used by the
AWS profile, replacing that tag's stock image. After authenticating Docker to
ECR, run the following commands. The default repository matches
`conf/platforms/aws_batch_nims.config`; set `OPENFOLD3_ECR_REPOSITORY` to use a
different repository.

```bash
set -euo pipefail
OPENFOLD3_ECR_REPOSITORY="${OPENFOLD3_ECR_REPOSITORY:-520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims}"
docker tag openfold3-nim-pae:1.5 "${OPENFOLD3_ECR_REPOSITORY}:openfold3-nim"
docker push "${OPENFOLD3_ECR_REPOSITORY}:openfold3-nim"
```

The local build tag remains `openfold3-nim-pae:1.5`. An explicit image digest can
be selected with `--openfold3_nim_image <image>`. These commands document the
publish procedure; a GPU smoke run must confirm the response and pipeline
filter before treating the deployed integration as validated.

## Response contract

| Field | Meaning |
| --- | --- |
| `pae` | Existing model confidence matrix, in angstroms, with verified padding removed. Directionality is preserved. |
| `pae_chain_ids`, `pae_residue_ids` | Chain and residue identifiers for both matrix axes in token order. Residue strings include insertion codes. |
| `atom_plddt` | Existing per-atom confidence on the 0–100 scale, before PDB rounding. |
| `atom_chain_ids`, `atom_residue_ids`, `atom_names` | Identifiers for each pLDDT value, in the exact returned PDB atom order. |

The exporter validates atom identities against the returned PDB and maps PAE
tokens using the inference batch's `atom_to_token_index` and `token_mask`. It
supports protein complexes with one token per residue. Ambiguous mappings,
atomised residues, unexpected mask layouts, invalid dimensions, and non-finite
confidence values fail explicitly. If the model has no PAE tensor, no PAE is
invented; the client must report it unavailable and reject requested PAE filtering.

## Evidence from the pinned image

These paths refer to source inside the image:

- `/opt/nim/inference.py` calls the active `api.pipeline.Pipeline`.
- `/opt/nim/api/component/inference_engine.py` runs
  `tensorrt_bionemo.models.openfold3.modeling.OpenFold3` and invokes
  `get_confidence_scores()`, storing the result in `outputs['confidence_scores']`.
- `/opt/nim/runner_args/runner_inference_baseline.yml` enables `pae_enabled`.
- `/usr/local/lib/python3.12/dist-packages/openfold3/core/metrics/aggregate_confidence_ranking.py`
  converts `pae_logits` into `confidence_scores['pae']` using the configured error
  bin centres. It multiplies the pLDDT expectation by 100. Both tensors retain
  batch and diffusion-sample axes.
- `/usr/local/lib/python3.12/dist-packages/openfold3/projects/of3_all_atom/config/model_config.py`
  defines 64 PAE bins over 0–32 angstroms (centres 0.25–31.75).
- `/opt/nim/api/pipeline.py` originally passed only scalar confidence fields to
  `StructureWithScores`; the response schema did not contain PAE or atom pLDDT.
- `/usr/local/lib/python3.12/dist-packages/openfold3/core/runners/writer.py`
  wrote full confidence files containing only `plddt` and `pde`. Enabling its
  `pae_enabled` option alone would not export the PAE matrix.

The extension patches only the HTTP response schema and assembly. It does not
use the separate, inactive generic TensorRT pipeline postprocessor, recompute
PAE with guessed bins, or derive PAE from PDE/ipTM.

Run the local mapping and patch-guard tests with:

```bash
python3 -m unittest discover -s tests/bin -p 'test_openfold3_nim_pae.py' -v
```

Check the installed Torch tensors, OpenFold3/Biotite PDB writer and Pydantic
response schema without loading a model or starting the server:

```bash
docker run --rm --platform linux/amd64 --network none \
  --mount "type=bind,source=${PWD}/tests/bin/test_openfold3_nim_image.py,target=/tmp/test_image.py,readonly" \
  openfold3-nim-pae:1.5 python /tmp/test_image.py
```
