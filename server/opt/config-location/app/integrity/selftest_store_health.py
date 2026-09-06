from __future__ import annotations

import json
import tempfile

from pathlib import Path

from .store_health import (
    build_store_health_integrity,
)


def write(
    path: Path,
    value,
):

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    path.write_text(
        json.dumps(
            value
        ),
        encoding="utf-8",
    )


def main() -> None:

    with tempfile.TemporaryDirectory() as td:

        root = Path(td)

        configs = (
            root
            / "configs"
        )

        latest = (
            root
            / "latest"
        )

        configs.mkdir()
        latest.mkdir()


        # cfg-a has Health.
        write(
            configs / "cfg-a.json",
            {
                "id": "cfg-a",
                "type": "vless",
            },
        )

        write(
            latest / "cfg-a.json",
            {
                "config_id": "cfg-a",
                "state": "healthy",
            },
        )


        # cfg-b is awaiting its first Health result.
        write(
            configs / "cfg-b.json",
            {
                "id": "cfg-b",
                "type": "vmess",
            },
        )


        # cfg-old is an orphan latest Health record.
        write(
            latest / "cfg-old.json",
            {
                "config_id": "cfg-old",
                "state": "failed",
            },
        )


        report = build_store_health_integrity(
            config_dir=configs,
            health_latest_dir=latest,
        )


        c = report["counts"]

        assert c["configs"] == 2
        assert c["health_latest"] == 2
        assert c["matched"] == 1
        assert c["orphan_health"] == 1
        assert c["configs_without_health"] == 1

        assert report[
            "orphan_health_ids"
        ] == [
            "cfg-old"
        ]

        assert report[
            "configs_without_health_ids"
        ] == [
            "cfg-b"
        ]

        assert (
            report["state"]
            ==
            "inconsistent"
        )


        # Healthy clean case.
        (
            latest
            / "cfg-old.json"
        ).unlink()

        write(
            latest / "cfg-b.json",
            {
                "config_id": "cfg-b",
                "state": "healthy",
            },
        )

        clean = build_store_health_integrity(
            config_dir=configs,
            health_latest_dir=latest,
        )

        assert (
            clean["state"]
            ==
            "healthy"
        )

        assert (
            clean["counts"][
                "orphan_health"
            ]
            ==
            0
        )

        assert (
            clean["counts"][
                "configs_without_health"
            ]
            ==
            0
        )


    print(
        "[PASS] FIX20.1 store-health selftest"
    )


if __name__ == "__main__":
    main()
