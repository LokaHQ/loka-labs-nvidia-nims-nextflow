FROM nvcr.io/nim/openfold/openfold3@sha256:6286cc7c02247ed3efe42f0f1af6c2f6f6a680b1e5cae669512c44b636aa42d2

USER root
COPY bin/openfold3_nim_pae.py /opt/nim/api/pae_export.py
COPY bin/patch_openfold3_nim.py /tmp/patch_openfold3_nim.py
RUN python /tmp/patch_openfold3_nim.py
USER nvs:1000
ENTRYPOINT []
