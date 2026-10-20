"""Scoped random-number generators for reproducible RFdiffusion sampling.

Independent reimplementation (not NVIDIA's code) of the same technique: an
isolated generator per RNG family, instead of mutating global state, so a run
can be seeded without affecting unrelated global RNG consumers.
"""
import random

import numpy as np
import torch


class RNGs:
    def __init__(self, seed=None):
        self.py = random.Random()
        self.np = np.random.RandomState()
        self.torch = torch.Generator()
        self.set_random_seed(seed)

    def set_random_seed(self, seed):
        if seed is None:
            return
        self.py.seed(seed)
        self.np.seed(seed)
        self.torch.manual_seed(seed)
