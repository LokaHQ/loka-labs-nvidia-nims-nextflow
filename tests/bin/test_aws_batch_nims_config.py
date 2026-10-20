#!/usr/bin/env python
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Verify the AWS NIM shared-memory option with the selected Nextflow runtime."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
NEXTFLOW_COMMAND = shlex.split(os.environ.get("NEXTFLOW_TEST_CMD", ""))


def groovy_string(value: object) -> str:
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


@unittest.skipUnless(NEXTFLOW_COMMAND, "Set NEXTFLOW_TEST_CMD for Nextflow integration tests")
class AwsBatchNimsConfigTests(unittest.TestCase):
    def test_openfold3_shared_memory_matches_nextflow_parser(self) -> None:
        with tempfile.TemporaryDirectory(prefix="aws-nims-config-") as temporary:
            directory = Path(temporary)
            workflow = directory / "main.nf"
            workflow.write_text(
                """nextflow.enable.dsl = 2

process OPENFOLD3_NIM {
    executor 'local'
    debug true

    output:
    stdout

    script:
    \"\"\"
    echo '${task.containerOptions}'
    \"\"\"
}

workflow {
    OPENFOLD3_NIM()
}
""",
                encoding="utf-8",
            )
            config = directory / "nextflow.config"
            config.write_text(
                f"includeConfig {groovy_string(REPOSITORY / 'conf/platforms/aws_batch_nims.config')}\n"
                f"workDir = {groovy_string(directory / 'work')}\n"
                "process.executor = 'local'\n"
                "process {\n"
                "    withName: OPENFOLD3_NIM {\n"
                "        cpus = 1\n"
                "        memory = '128 MB'\n"
                "        accelerator = 0\n"
                "        container = ''\n"
                "    }\n"
                "}\n"
                "docker.enabled = false\n"
                "singularity.enabled = false\n"
                "apptainer.enabled = false\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment.setdefault("NXF_SYNTAX_PARSER", "v1")
            result = subprocess.run(
                [
                    *NEXTFLOW_COMMAND,
                    "-log",
                    str(directory / "nextflow.log"),
                    "run",
                    str(workflow),
                    "-c",
                    str(config),
                    "-ansi-log",
                    "false",
                ],
                cwd=directory,
                env=environment,
                text=True,
                capture_output=True,
                timeout=180,
                check=False,
            )
            diagnostic = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, diagnostic)
            match = re.search(r"version (\d+)\.(\d+)\.(\d+)", diagnostic)
            self.assertIsNotNone(match, diagnostic)
            version = tuple(int(value) for value in match.groups())
            expected = "--shm-size 16g" if version >= (24, 4, 4) else "--shm-size 16384"
            self.assertRegex(diagnostic, rf"(?m)^{re.escape(expected)}$")


if __name__ == "__main__":
    unittest.main()
