from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT=Path(
    "/opt/config-location"
)

HERE=Path(__file__).resolve().parent


with tempfile.TemporaryDirectory() as td:

    out=Path(td)/"current.json"

    subprocess.run(
        [
            str(
                ROOT
                / "venv"
                / "bin"
                / "python"
            ),
            str(
                HERE
                / "capture_universal.py"
            ),
            str(
                HERE
                / "fixtures"
            ),
            str(out),
        ],
        check=True,
        env={
            **__import__(
                "os"
            ).environ,
            "PYTHONPATH":
                str(ROOT),
        },
    )

    baseline=(
        HERE
        / "golden"
        / "baseline.json"
    )

    if (
        out.read_bytes()
        !=
        baseline.read_bytes()
    ):
        raise SystemExit(
            "UNIVERSAL JSON GOLDEN REGRESSION"
        )


print(
    "[PASS] universal JSON regression"
)
