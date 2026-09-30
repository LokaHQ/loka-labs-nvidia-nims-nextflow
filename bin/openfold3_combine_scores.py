#!/usr/bin/env python3
"""Concatenate per-design OpenFold3 score TSVs into one file.

Usage: openfold3_combine_scores.py <scores_dir> -o <output.tsv>
"""
import glob
import sys

scores_dir = sys.argv[1]
out_path = sys.argv[sys.argv.index("-o") + 1]

files = sorted(glob.glob(f"{scores_dir}/*.scores.tsv"))
with open(out_path, "w") as out:
    for i, path in enumerate(files):
        with open(path) as f:
            lines = f.readlines()
        out.writelines(lines if i == 0 else lines[1:])
