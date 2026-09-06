from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


DEFAULT_PATH = Path(
    "/etc/config-location/health-settings.json"
)


@dataclass(frozen=True)
class HealthSettings:
    max_workers: int = 10
    batch_size: int = 20

    startup_timeout: float = 6.0
    download_timeout: float = 12.0
    upload_timeout: float = 15.0

    upload_payload_bytes: int = 65536
    runtime_retry_count: int = 2


def load_health_settings(
    path: Path = DEFAULT_PATH,
) -> HealthSettings:

    if not path.exists():
        return HealthSettings()

    obj = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    settings = HealthSettings(
        max_workers=int(
            obj.get("max_workers", 10)
        ),
        batch_size=int(
            obj.get("batch_size", 20)
        ),
        startup_timeout=float(
            obj.get("startup_timeout", 6)
        ),
        download_timeout=float(
            obj.get("download_timeout", 12)
        ),
        upload_timeout=float(
            obj.get("upload_timeout", 15)
        ),
        upload_payload_bytes=int(
            obj.get(
                "upload_payload_bytes",
                65536,
            )
        ),
        runtime_retry_count=int(
            obj.get(
                "runtime_retry_count",
                2,
            )
        ),
    )

    if not 1 <= settings.max_workers <= 200:
        raise ValueError(
            "max_workers must be 1..200"
        )

    if not 1 <= settings.batch_size <= 10000:
        raise ValueError(
            "batch_size must be 1..10000"
        )

    for value in (
        settings.startup_timeout,
        settings.download_timeout,
        settings.upload_timeout,
    ):
        if not 1 <= value <= 120:
            raise ValueError(
                "timeout must be 1..120 seconds"
            )

    if not 0 <= settings.runtime_retry_count <= 10:
        raise ValueError(
            "runtime_retry_count must be 0..10"
        )

    return settings
