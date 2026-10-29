#!/usr/bin/env python3
"""FastRelax an already-threaded structure, using the same PyRosetta config as
thread_and_relax.py.

The baseline arm's ProteinMPNN threads its own sequence, so it needs the relax
without the threading. Running the identical XML through the identical
container is what makes the two arms' relax step comparable.
"""
import os

from pyrosetta import init, pose_from_pdb
from pyrosetta.rosetta import protocols

INPUT_PDB = os.environ["RELAX_INPUT_PDB"]
OUTPUT_PDB = os.environ["RELAX_OUTPUT_PDB"]
RELAX_XML = os.environ["RELAX_XML"]

init("-beta_nov16 -in:file:silent_struct_type binary -mute all"
     " -use_terminal_residues true -mute basic.io.database core.scoring")

pose = pose_from_pdb(INPUT_PDB)

objs = protocols.rosetta_scripts.XmlObjects.create_from_file(RELAX_XML)
fast_relax = objs.get_mover("FastRelax")
fast_relax.apply(pose)

pose.dump_pdb(OUTPUT_PDB)
