# RFdiffusion NIM Workflow

`--method rfd_nim` runs RFdiffusion NIM, ProteinMPNN NIM, threading and relaxation, independent per-chain MSA search, OpenFold3 NIM co-folding, and confidence filtering. The `aws_batch_nims` profile runs these stages as separate AWS Batch tasks and requires site-specific queues, container images and storage to be configured.

The AWS profile reads the NGC API key from the Secrets Manager ID in `params.ngc_api_key_secret`. Each NIM task retrieves the value through the pipeline's Batch task role, which has read access to that one secret and the pipeline S3 buckets. The credential is absent from Nextflow task scripts and S3 work files. Local execution can instead inherit `NGC_API_KEY` from the launch environment. Never pass the key as a Nextflow parameter.

The stock OpenFold3 NIM HTTP response omits a PAE matrix that its active inference implementation already computes. This integration therefore requires a version-specific response patch to expose genuine PAE and its residue mapping. The patch changes response serialisation only; it does not change model weights, inference or predicted structures. A stock response without PAE still causes the required interaction PAE filter to fail explicitly.

## OpenFold3 image

The response patch is maintained in `bin/patch_openfold3_nim.py`, with image build and publish instructions in `assets/openfold3_nim/README.md`. The AWS profile uses the existing `openfold3-nim` ECR tag, which must be updated to the patched image. The local build tag is `openfold3-nim-pae:1.5`; `--openfold3_nim_image <image>` can select a specific image digest. Build, publish and validate the patched image for the deployment before running this workflow; the tag alone does not establish that the patch is present.

The patch exposes the genuine PAE already calculated from the model's `pae_logits` and its own bin centres. It retains the native response fields and adds the matrix with chain and residue identifiers. Unexpected source versions must fail patch validation rather than silently applying an incompatible change. The downstream client independently validates the returned matrix and residue mapping.

## Complex input and prediction

OpenFold3 receives sequences from each **threaded complex PDB**: chain A is the designed binder and chain B is the target crop retained by RFdiffusion. This preserves the designed binder–target pairing and avoids reintroducing the original target's full sequence.

The pipeline sends both sequences in one request to the public ColabFold MMseqs2 service and saves the returned A3Ms. Searches are unpaired: chain A and B each receive evolutionary context, but hits from the two alignments are not paired with one another. This is appropriate for a designed binder and a natural target that do not share a natural interaction history. The first sequence in each returned A3M must exactly match its PDB chain before inference can start.

MSA tasks run on the CPU queue with `maxForks = 1`, as requested by the public service. They remain separate from GPU inference so `-resume` can reuse a completed search. A novel binder may return only its query or very few hits; a natural target such as PD-L1 can return thousands. These are alignment rows used as model evidence, not additional designs or PDB inputs.

OpenFold3 co-folds these sequences. It does not use the threaded coordinates as an initial guess, so its predictions are not equivalent to the baseline AlphaFold2 initial guess refinement. Returned chain sequences and the response design identifier are checked before a prediction is accepted for scoring.

`--of3_diffusion_samples` must be `1`. Other values are rejected to keep one prediction and one score row per design, without selecting among multiple sampled structures.

## Confidence filtering

The default filter expression is:

```text
--refold_af2ig_filters 'pae_interaction<=10;plddt_binder>=80'
```

Both conditions must pass. A design with valid scores that fails either threshold is collected as rejected. Missing, nonnumeric or nonfinite requested scores cause an error before any acceptance or rejection is written. A missing `pae_interaction` produces an explicit message that genuine PAE is unavailable and that the OpenFold3 integration is incomplete. PDE and ipTM are not substitutes for PAE.

Prediction and filtering are separate processes. Completed predictions, normalised score tables and complete request/response JSON files are published independently of the filter, retaining evidence when PAE filtering fails. A blank PAE value indicates unavailable evidence, not a poor interaction score.

### Chain pLDDT

The patched response supplies unrounded per-atom pLDDT on the 0–100 scale, with atom identities validated against the returned PDB. `plddt_binder` and `plddt_target` are calculated separately by averaging those original heavy-atom values within each residue, then averaging the residue means with equal weight in that chain. For a stock response, the client can use its PDB B-factor values, which are rounded to two decimal places. Hydrogen and deuterium atoms are excluded. Chain, residue number and insertion code distinguish residues.

Inspection of an existing 78-residue binder prediction confirmed that atom confidences differ within every residue. Its residue-balanced binder pLDDT is `66.9752121212`; an all-atom mean would give `65.1896721311`, and a C-alpha-only mean would give `68.6582051282`. This check establishes why the two-stage average is required. The saved PDB retains the original atom confidence values.

### Interaction PAE

When a genuine PAE matrix and verified residue mapping are available, the normalisation follows the baseline's formula:

```text
pae_interaction = (mean(PAE[binder, target]) + mean(PAE[target, binder])) / 2
```

The score is in angstroms and includes both directional off-diagonal blocks over all binder–target residue pairs. The matrix must match the returned complex, with explicit chain and residue identifiers for its rows and columns. Dimensions alone are insufficient to establish ordering. The patched response supplies a structure entry containing `pae`, `pae_chain_ids` and `pae_residue_ids`; the stock HTTP response omits these fields.

The baseline container's [published build recipe](https://github.com/Australian-Protein-Design-Initiative/containers/blob/main/dockerfiles/af2_initial_guess/nv-cuda12/Dockerfile) pins `dl_binder_design` commit `cafa385`. The [scoring source at that commit](https://github.com/nrbennet/dl_binder_design/blob/cafa385/af2_initial_guess/predict.py#L168-L207) averages binder residue pLDDTs and both directional interaction PAE means. This provenance was checked against the pinned source; the deployed AF2 container filesystem was not extracted. Matching the score definitions does not make OpenFold3 and AF2 confidence estimates interchangeable.

## Outputs

OpenFold3 outputs are published under `${outdir}/rfd/openfold3_nim/`:

| Path | Contents |
|------|----------|
| `queries/<design_id>.fasta` | The binder A and target B sequences submitted together for unpaired search |
| `msas/<design_id>.A.a3m` | Complete binder alignment, with the exact binder query first |
| `msas/<design_id>.B.a3m` | Complete target alignment, with the exact target query first |
| `pdbs/<design_id>.pdb` | Predicted binder A and cropped target B complex, with original atom pLDDT values |
| `scores/<design_id>.of3_scores.tsv` | One normalised score row for the prediction |
| `raw/<design_id>.request.json` | Complete request, including both query sequences and alignments |
| `raw/<design_id>.response.json` | Complete original response bytes, including native confidence fields |
| `filtered/<design_id>.filtered.tsv` | Original score columns plus `openfold3_pass_filter`, once validation succeeds |
| `filtered/accepted/<design_id>.pdb` | Prediction passing both required filters |
| `filtered/rejected/<design_id>.pdb` | Prediction with valid scores that fails either filter |

The normalised TSV includes `description`, `plddt_binder`, `plddt_target`, `pae_interaction` and `filename`. `description` exactly matches the predicted PDB's filename stem. Native `confidence_score`, `complex_plddt_score`, `complex_pde_score`, `ptm_score` and `iptm_score` fields remain in the table when supplied; all response fields remain in the raw JSON. Unavailable PAE is recorded as a blank cell and causes the required filter to fail explicitly.

## CPU verification

The confidence and filter tests use Python's standard library and require Python 3.10 or later. Run from the repository root:

```bash
python3 -m unittest discover -s tests/bin -p 'test_openfold3_nim_call.py' -v
python3 -m unittest discover -s tests/bin -p 'test_openfold3_msa.py' -v
python3 -m unittest discover -s tests/bin -p 'test_filter_openfold3_scores.py' -v
```

These tests cover MSA chain matching and retention, preservation of chain sequences and target crop, residue-balanced pLDDT, both PAE directions with explicit mapping, complete response retention, matching design identifiers, and errors for missing or invalid confidence values. They require no GPU, credentials or network access. They validate the integration logic; an inference response from the patched image is still required to verify the complete deployment.
