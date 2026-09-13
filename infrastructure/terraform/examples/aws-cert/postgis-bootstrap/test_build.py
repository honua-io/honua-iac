#!/usr/bin/env python3
# Copyright (c) Honua. All rights reserved.
# Licensed under the Elastic License 2.0. See LICENSE in the project root.

"""Exercise the actual local-exec shell with isolated interpreter candidates."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class BuildInterpreterTests(unittest.TestCase):
    def test_interpreter_selection(self):
        source = Path(__file__).resolve().parent.parent / "postgis-bootstrap.tf"
        command = textwrap.dedent(source.read_text().split("<<-EOT\n", 1)[1].split("    EOT", 1)[0])
        cases = [
            ({"python3": True}, "python3"),
            ({"python": True}, "python"),
            ({"python3": True, "python": True}, "python3"),
            ({"python3": False, "python": True}, "python"),
            ({"python3": False}, None),
            ({"python3": False, "python": False}, None),
            ({}, None),
        ]
        for candidates, expected in cases:
            with self.subTest(candidates=candidates), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                log = root / "build.log"
                for name, has_pip in candidates.items():
                    executable = root / name
                    executable.write_text(
                        "#!/bin/bash\n"
                        'if [[ "$*" == "-m pip --version" ]]; then\n'
                        f"  exit {0 if has_pip else 1}\n"
                        "fi\n"
                        f"printf '%s\\n' '{name}' >> \"$BUILD_LOG\"\n"
                        f"exit {0 if has_pip else 1}\n"
                    )
                    executable.chmod(0o755)
                result = subprocess.run(
                    ["/bin/bash", "-c", command], capture_output=True, text=True,
                    env={**os.environ, "PATH": directory, "BUILD_LOG": str(log)},
                )
                if expected:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(log.read_text(), expected + "\n")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("requires python3 (or python) with pip on PATH", result.stderr)
                    self.assertFalse(log.exists(), "Build must not start without pip")


if __name__ == "__main__":
    unittest.main()
