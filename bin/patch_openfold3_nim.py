#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Apply the response-only confidence extension to the audited OpenFold3 NIM."""

import logging
import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA256 = {
    "api/pipeline.py": "26c7fbd274e970d5f569bea58f4784a5a80def6b285ac584eda972ee7585500d",
    "api/dto/structure_with_scores.py": "f3f7146d07ce83863e86448a9b00c4f59c2900c1c65e15a578aeb91976f58eda",
}

RESPONSE_FIELDS = """
    pae: Optional[List[List[float]]] = None
    pae_chain_ids: Optional[List[str]] = None
    pae_residue_ids: Optional[List[str]] = None
    atom_plddt: Optional[List[float]] = None
    atom_chain_ids: Optional[List[str]] = None
    atom_residue_ids: Optional[List[str]] = None
    atom_names: Optional[List[str]] = None

"""


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"Expected exactly one patch anchor: {old!r}")
    return source.replace(old, new, 1)


def patch_sources(sources: dict[str, bytes]) -> dict[str, str]:
    for relative, expected in EXPECTED_SHA256.items():
        actual = hashlib.sha256(sources[relative]).hexdigest()
        if actual != expected:
            raise ValueError(f"Unsupported OpenFold3 source {relative}: SHA256 {actual}")

    pipeline = sources["api/pipeline.py"].decode()
    pipeline = replace_once(
        pipeline,
        "from api.dto.structure_with_scores import StructureWithScores\n",
        "from api.dto.structure_with_scores import StructureWithScores\n"
        "from api.pae_export import export_confidence\n",
    )
    pipeline = replace_once(
        pipeline,
        "                                structure=structure_content,\n",
        "                                **export_confidence(\n"
        "                                    result, i_batch, i_sample, structure_content, output_format\n"
        "                                ),\n"
        "                                structure=structure_content,\n",
    )
    schema = replace_once(
        sources["api/dto/structure_with_scores.py"].decode(),
        "    structure: str = Field(\n",
        RESPONSE_FIELDS + "    structure: str = Field(\n",
    )
    patched = {"api/pipeline.py": pipeline, "api/dto/structure_with_scores.py": schema}
    for relative, source in patched.items():
        compile(source, relative, "exec")
    return patched


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/opt/nim"))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        sources = {relative: (args.root / relative).read_bytes() for relative in EXPECTED_SHA256}
        patched = patch_sources(sources)
        helper = args.root / "api/pae_export.py"
        if not helper.is_file():
            raise ValueError(f"Confidence export helper is missing: {helper}")
        for relative, source in patched.items():
            (args.root / relative).write_text(source)
        logging.info("Extended OpenFold3 response with existing PAE and atom pLDDT tensors")
    except (OSError, ValueError, SyntaxError) as error:
        parser.exit(1, f"OpenFold3 response patch failed: {error}\n")


if __name__ == "__main__":
    main()
