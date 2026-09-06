from __future__ import annotations

import json
import subprocess
import sys
import tempfile

from pathlib import Path


ROOT=Path(
    "/opt/config-location"
)

HERE=Path(__file__).resolve().parent

FIXTURES=(
    HERE / "fixtures"
)

BASELINE=(
    HERE
    / "golden"
    / "baseline.json"
)

CAPTURE=(
    HERE / "capture.py"
)


def main() -> None:

    baseline=json.loads(
        BASELINE.read_text(
            encoding="utf-8"
        )
    )

    module_name=baseline[
        "module"
    ]


    with tempfile.TemporaryDirectory() as td:

        out=(
            Path(td)
            / "current.json"
        )

        subprocess.run(
            [
                str(
                    ROOT
                    / "venv"
                    / "bin"
                    / "python"
                ),

                str(CAPTURE),

                str(ROOT),

                module_name,

                str(FIXTURES),

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


        current=json.loads(
            out.read_text(
                encoding="utf-8"
            )
        )


    # detector SHA is intentionally ignored here:
    # refactoring changes source SHA but behavior must stay.
    baseline.pop(
        "detector_sha256",
        None
    )

    current.pop(
        "detector_sha256",
        None
    )


    if baseline != current:

        print(
            json.dumps(
                {
                    "baseline":
                        baseline,

                    "current":
                        current,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
        )

        raise SystemExit(
            "PARSER GOLDEN REGRESSION"
        )


    print(
        "[PASS] parser golden regression"
    )


if __name__ == "__main__":
    main()
