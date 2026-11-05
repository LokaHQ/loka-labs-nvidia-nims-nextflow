FROM nvcr.io/nvidia/pytorch:24.07-py3
LABEL org.opencontainers.image.source=https://github.com/Australian-Protein-Design-Initiative/containers

RUN apt-get -q update \ 
  && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
  git \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get autoremove -y \
  && apt-get clean

RUN git clone https://github.com/RosettaCommons/RFdiffusion.git /app/RFdiffusion
#COPY . /app/RFdiffusion/

RUN apt-get -q update \
  && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
  git \
  wget \
  curl \
  vim \
  htop \
  python3-pip \
  && python3 -m pip install -q -U --no-cache-dir pip \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get autoremove -y \
  && apt-get clean \
  && pip install -q --no-cache-dir \
  dgl -f https://data.dgl.ai/wheels/torch-2.4/cu124/repo.html \
  e3nn==0.5.5 \
  wandb==0.19.2 \
  pynvml==11.4.1 \
  git+https://github.com/NVIDIA/dllogger#egg=dllogger \
  decorator==5.1.1 \
  hydra-core==1.3.2 \
  pyrsistent==0.20.0 \
  "numpy<2" \
  /app/RFdiffusion/env/SE3Transformer \
  && pip install --no-cache-dir /app/RFdiffusion --no-deps

# Some extra monitoring tools
RUN pip install -q --no-cache-dir nvitop gpustat

# Bake model weights into the container for easier setup
RUN mkdir -p "/usr/local/lib/python3.10/dist-packages/rfdiffusion/inference/../../models" \
  && wget -c -P "/usr/local/lib/python3.10/dist-packages/rfdiffusion/inference/../../models" \
  http://files.ipd.uw.edu/pub/RFdiffusion/6f5902ac237024bdd0c176cb93063dc4/Base_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/e29311f6f1bf1af907f9ef9f44b8328b/Complex_base_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/60f09a193fb5e5ccdc4980417708dbab/Complex_Fold_base_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/74f51cfb8b440f50d70878e05361d8f0/InpaintSeq_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/76d00716416567174cdb7ca96e208296/InpaintSeq_Fold_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/5532d2e1f3a4738decd58b19d633b3c3/ActiveSite_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/12fc204edeae5b57713c5ad7dcb97d39/Base_epoch8_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/f572d396fae9206628714fb2ce00f72e/Complex_beta_ckpt.pt \
  http://files.ipd.uw.edu/pub/RFdiffusion/1befcb9b28e2f778f53d47f18b7597fa/RF_structure_prediction_weights.pt

RUN mkdir -p /models && ln -s /usr/local/lib/python3.10/dist-packages/rfdiffusion/inference/../../models /models/rfdiffusion

WORKDIR /app/RFdiffusion

ENV DGLBACKEND="pytorch"

ENTRYPOINT ["python3", "/app/RFdiffusion/scripts/run_inference.py"]
