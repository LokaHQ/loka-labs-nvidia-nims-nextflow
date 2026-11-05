# colabfold_search with GPU-accelerated MMseqs2.
#
# Why: quay.io/nf-core/proteinfold_colabfold:1.1.1 ships MMseqs2 15.6f452 and a
# colabfold_search with no --gpu flag. MMseqs2 added GPU support in release 16
# and ColabFold exposed it in v1.6.0. Our 15.6f452 is three releases behind,
# which is why it could not open ColabFold's own GPU-format uniref30_2302
# (dbtype 524288 plus a .GPU_READY marker) and died with "No k-mer could be
# extracted ... Prefilter died" on 2026-10-29.
#
# That is also why this image exists rather than another database rebuild: the
# GPU format is readable, by a current MMseqs2.
#
# What it enables: an MSA comparison that measures the NIM rather than the
# hardware. NVIDIA's MSA Search NIM is MMseqs2 18 on GPU; comparing it against
# MMseqs2 15 on CPU measures GPU versus CPU, which is free to anyone. Comparing
# it against this image measures what the NIM actually adds.
#
# Note the open-source path needs only ONE GPU - MMseqs2 streams databases
# larger than GPU memory at ~63-65% of in-memory speed - where the NIM requires
# two 48 GB GPUs because its GPU Server holds databases resident.
#
# Build (needs linux/amd64; see build.sh):
#   docker build --platform linux/amd64 -t colabfold-gpu .

FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ARG MMSEQS_VERSION=17-b804f
ARG COLABFOLD_VERSION=1.6.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# The -gpu tarball; the plain linux build has no GPU prefilter. MMseqs2 needs
# a Turing or newer GPU (Ampere+ for full speed), glibc >= 2.29 and driver
# >= 525.60.13 - all satisfied by g6e (L40S) on this CUDA base.
RUN curl -fsSL -o /tmp/mmseqs.tar.gz \
        "https://github.com/soedinglab/MMseqs2/releases/download/${MMSEQS_VERSION}/mmseqs-linux-gpu.tar.gz" \
    && tar -xzf /tmp/mmseqs.tar.gz -C /opt \
    && rm /tmp/mmseqs.tar.gz \
    && ln -s /opt/mmseqs/bin/mmseqs /usr/local/bin/mmseqs

# --no-deps keeps the folding stack (jax, alphafold) out: only the search CLI
# is wanted here, and its dependencies are the two listed below.
RUN pip3 install --no-cache-dir "numpy<2" requests tqdm \
    && pip3 install --no-cache-dir --no-deps "colabfold==${COLABFOLD_VERSION}" \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

# Fail the build rather than a benchmark task if either tool is wrong.
RUN mmseqs version \
    && mmseqs version | grep -qE '^(1[6-9]|[2-9][0-9])' \
    && colabfold_search --help | grep -q -- '--gpu'

ENTRYPOINT []
CMD ["/bin/bash"]
