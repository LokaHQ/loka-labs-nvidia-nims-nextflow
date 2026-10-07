#!/usr/bin/env python3
"""Ad-hoc smoke test: call a locally-running MSA Search NIM's
/biology/colabfold/msa-search/predict endpoint with a real sequence and save
the result. Not part of the pipeline - standalone evaluation only.
"""
import json
import time
import urllib.request

sequence = (
    "APLAVAAAAAAEARAAAAELAALGGAEEAAALTAEAEAALAAAEAATDPAVKAAEADKVRAARGRAEALVARALAKKE"
)

payload = {
    "sequence": sequence,
    "databases": ["all"],
    "e_value": 0.0001,
    "iterations": 1,
    "search_type": "colabfold",
    "output_alignment_formats": ["a3m"],
}

start = time.time()
req = urllib.request.Request(
    "http://localhost:8000/biology/colabfold/msa-search/predict",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=3600) as resp:
    result = json.load(resp)
elapsed = time.time() - start

with open("msa_nim_response.json", "w") as f:
    json.dump(result, f, indent=2)

print(f"Elapsed: {elapsed:.1f}s")
print("Top-level response keys:", list(result.keys()))
