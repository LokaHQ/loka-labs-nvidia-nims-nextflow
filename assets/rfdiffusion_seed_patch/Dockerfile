# Seed-patched RFdiffusion (tag: rfdiffusion-seed-patch-v3).
# Reconstructed from the image build history; the sources beside this file were
# extracted from the built image itself.
#
# Base is the ECR copy of ghcr.io/australian-protein-design-initiative/containers/rfdiffusion:pytorch2407
# with the entrypoint cleared (see ../nim_entrypoint_fix/Dockerfile.rfdiffusion).
FROM 520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims@sha256:4f554a1cf2f9cec2f4bb6962d9a03521284a6d9d74e776a6753ddcfd29d5c42f

# The image has RFdiffusion in two places: the git checkout under /app and the
# pip-installed copy in dist-packages. Both must be patched or the unpatched one wins.
COPY rfdiffusion/rng.py                     /app/RFdiffusion/rfdiffusion/rng.py
COPY rfdiffusion/diffusion.py               /app/RFdiffusion/rfdiffusion/diffusion.py
COPY rfdiffusion/contigs.py                 /app/RFdiffusion/rfdiffusion/contigs.py
COPY rfdiffusion/inference/utils.py         /app/RFdiffusion/rfdiffusion/inference/utils.py
COPY rfdiffusion/inference/model_runners.py /app/RFdiffusion/rfdiffusion/inference/model_runners.py
COPY rfdiffusion/potentials/potentials.py   /app/RFdiffusion/rfdiffusion/potentials/potentials.py
COPY rfdiffusion/potentials/manager.py      /app/RFdiffusion/rfdiffusion/potentials/manager.py
COPY run_inference.py                       /app/RFdiffusion/scripts/run_inference.py

COPY rfdiffusion/rng.py                     /usr/local/lib/python3.10/dist-packages/rfdiffusion/rng.py
COPY rfdiffusion/diffusion.py               /usr/local/lib/python3.10/dist-packages/rfdiffusion/diffusion.py
COPY rfdiffusion/contigs.py                 /usr/local/lib/python3.10/dist-packages/rfdiffusion/contigs.py
COPY rfdiffusion/inference/utils.py         /usr/local/lib/python3.10/dist-packages/rfdiffusion/inference/utils.py
COPY rfdiffusion/inference/model_runners.py /usr/local/lib/python3.10/dist-packages/rfdiffusion/inference/model_runners.py
COPY rfdiffusion/potentials/potentials.py   /usr/local/lib/python3.10/dist-packages/rfdiffusion/potentials/potentials.py
COPY rfdiffusion/potentials/manager.py      /usr/local/lib/python3.10/dist-packages/rfdiffusion/potentials/manager.py
