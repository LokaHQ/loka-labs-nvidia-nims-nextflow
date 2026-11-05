# Seed-patched ProteinMPNN (tag: proteinmpnn-seed-patch-v2).
# Reconstructed from the image build history; dl_interface_design.py beside this
# file was extracted from the built image itself.
#
# Base is the ECR copy of
# ghcr.io/australian-protein-design-initiative/containers/proteinmpnn_dl_binder_design:latest
FROM 520168724997.dkr.ecr.us-east-1.amazonaws.com/nvidia-nims@sha256:149b07db5bb17196f6ab3d43ded88acafab41d554347c21657869512733add3c

# Adds a -seed flag and seeds torch/random/numpy; upstream left them unseeded,
# so decoding order (and the sequence) differed on every run.
COPY dl_interface_design.py /app/dl_binder_design/mpnn_fr/dl_interface_design.py
RUN chmod +x /app/dl_binder_design/mpnn_fr/dl_interface_design.py
