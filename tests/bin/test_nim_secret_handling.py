#!/usr/bin/env python3
"""Regression checks for NIM credential handling."""

from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
NIM_MODULES = (
    REPOSITORY / "modules/local/rfd/rfdiffusion_nim.nf",
    REPOSITORY / "modules/local/rfd/dl_binder_design_nim.nf",
    REPOSITORY / "modules/local/rfd/openfold3_nim.nf",
)


class NimSecretHandlingTests(unittest.TestCase):
    def test_ngc_key_is_not_interpolated_into_task_scripts(self) -> None:
        for module in NIM_MODULES:
            source = module.read_text()
            with self.subTest(module=module.name):
                self.assertNotIn("System.getenv('NGC_API_KEY')", source)
                self.assertIn("secretsmanager get-secret-value", source)
                self.assertIn(r"\${NGC_API_KEY:-}", source)


if __name__ == "__main__":
    unittest.main()
