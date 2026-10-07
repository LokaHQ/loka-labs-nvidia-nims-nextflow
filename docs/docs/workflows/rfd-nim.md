# RFdiffusion NIM Workflow

`--method rfd_nim` runs RFdiffusion NIM, ProteinMPNN NIM, threading and relaxation, independent per-chain MSA search, OpenFold3 NIM co-folding, and BindCraft-derived interface scoring. The `aws_batch_nims` profile runs these stages as separate AWS Batch tasks and requires site-specific queues, container images and storage to be configured.

The AWS profile reads the NGC API key from the Secrets Manager ID in `params.ngc_api_key_secret`. Each NIM task retrieves the value through the pipeline's Batch task role, which has read access to that one secret and the pipeline S3 buckets. The credential is absent from Nextflow task scripts and S3 work files. Local execution can instead inherit `NGC_API_KEY` from the launch environment. Never pass the key as a Nextflow parameter.

OpenFold3 receives a 16 GiB shared-memory allocation on AWS Batch. Nextflow 24.04.3 and supported stable runtimes from 24.04.4 onward use incompatible `shm-size` parsers, so the profile selects the correct representation from the running Nextflow version. No launcher-specific override is required.

The stock OpenFold3 NIM HTTP response omits a PAE matrix that its active inference implementation already computes. A version-specific response patch exposes genuine PAE and its residue mapping so the workflow can report interaction PAE. The patch changes response serialisation only; it does not change model weights, inference or predicted structures. A stock response continues through BindCraft scoring with `pae_interaction` left blank.

## OpenFold3 image

The response patch is maintained in `bin/patch_openfold3_nim.py`, with image build and publish instructions in `assets/openfold3_nim/README.md`. The AWS profile uses the existing `openfold3-nim` ECR tag, which must be updated to the patched image. The local build tag is `openfold3-nim-pae:1.5`; `--openfold3_nim_image <image>` can select a specific image digest. Build, publish and validate the patched image for the deployment before running this workflow; the tag alone does not establish that the patch is present.

The patch exposes the genuine PAE already calculated from the model's `pae_logits` and its own bin centres. It retains the native response fields and adds the matrix with chain and residue identifiers. Unexpected source versions must fail patch validation rather than silently applying an incompatible change. The downstream client independently validates the returned matrix and residue mapping.

## Complex input and prediction

OpenFold3 receives sequences from each **threaded complex PDB**: chain A is the designed binder and chain B is the target crop retained by RFdiffusion. This preserves the designed binder–target pairing and avoids reintroducing the original target's full sequence.

The pipeline sends both sequences in one request to the public ColabFold MMseqs2 service and saves the returned A3Ms. Searches are unpaired: chain A and B each receive evolutionary context, but hits from the two alignments are not paired with one another. This is appropriate for a designed binder and a natural target that do not share a natural interaction history. The first sequence in each returned A3M must exactly match its PDB chain before inference can start.

MSA tasks run on the CPU queue with `maxForks = 1`, as requested by the public service. They remain separate from GPU inference so `-resume` can reuse a completed search. A novel binder may return only its query or very few hits; a natural target such as PD-L1 can return thousands. These are alignment rows used as model evidence, not additional designs or PDB inputs.

OpenFold3 co-folds these sequences. It does not use the threaded coordinates as an initial guess, so its predictions are not equivalent to the baseline AlphaFold2 initial guess refinement. Returned chain sequences and the response design identifier are checked before a prediction is written for scoring.

`--of3_diffusion_samples` must be `1`. Other values are rejected to keep one prediction and one score row per design, without selecting among multiple sampled structures.

## Confidence metrics

OpenFold3 publishes normalised confidence scores for each prediction without accepting or rejecting designs. Every predicted PDB proceeds directly to BindCraft-derived scoring. A blank `pae_interaction` value indicates unavailable evidence, not a poor interaction score; PDE and ipTM are not substituted for PAE.

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

## BindCraft-derived scoring

The workflow sends every OpenFold3 PDB directly to the repository's extracted BindCraft scorer. The CPU-only process performs its own PyRosetta relaxation and reports metrics such as clashes, interface dG and dSASA, shape complementarity, packstat, hydrogen bonds, buried unsatisfied hydrogen bonds, interface residues and secondary structure. This is the BindCraft scoring code, not the full BindCraft design workflow.

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
| `extra_scores/<design_id>.tsv` | BindCraft-derived PyRosetta and interface metrics for the prediction |

The normalised TSV includes `description`, `plddt_binder`, `plddt_target`, `pae_interaction` and `filename`. `description` exactly matches the predicted PDB's filename stem. Native `confidence_score`, `complex_plddt_score`, `complex_pde_score`, `ptm_score` and `iptm_score` fields remain in the table when supplied; all response fields remain in the raw JSON. Unavailable PAE is recorded as a blank cell.

## CPU verification

The confidence tests use Python's standard library and require Python 3.10 or later. Run from the repository root:

```bash
python3 -m unittest discover -s tests/bin -p 'test_openfold3_nim_call.py' -v
python3 -m unittest discover -s tests/bin -p 'test_openfold3_msa.py' -v
NEXTFLOW_TEST_CMD=nextflow python3 -m unittest tests.bin.test_aws_batch_nims_config -v
```

These tests cover MSA chain matching and retention, preservation of chain sequences and target crop, residue-balanced pLDDT, both PAE directions with explicit mapping, complete response retention, matching design identifiers, errors for missing or invalid confidence values, and the AWS shared-memory representation selected by the active Nextflow runtime. They require no GPU or credentials. The first two require no network access; the configuration test uses the installed Nextflow launcher. They validate the integration logic; an inference response from the patched image is still required to verify the complete deployment.
