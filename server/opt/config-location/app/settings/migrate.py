from __future__ import annotations

import json

from pathlib import Path

from app.settings.engine import (
    STORE,
    default_settings,
)


OLD_PROJECT = Path(
    "/etc/config-location/"
    "config-location/settings.json"
)

OLD_HEALTH = Path(
    "/etc/config-location/"
    "health-settings.json"
)

OLD_ADAPTIVE = Path(
    "/etc/config-location/"
    "health-adaptive.json"
)


def _read(
    path: Path,
) -> dict:

    try:
        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        return (
            obj
            if isinstance(
                obj,
                dict,
            )
            else {}
        )

    except Exception:
        return {}


def build_initial() -> dict:

    result = default_settings()

    project = _read(
        OLD_PROJECT
    )

    fetcher = project.get(
        "fetcher"
    )

    if isinstance(
        fetcher,
        dict,
    ):

        for key in (
            "enabled",
            "global_concurrency",
            "connect_timeout_seconds",
            "read_timeout_seconds",
            "total_timeout_seconds",
            "max_response_bytes",
            "max_redirects",
        ):
            if key in fetcher:
                result[
                    "fetcher"
                ][key] = fetcher[key]

    health = _read(
        OLD_HEALTH
    )

    for key in (
        "max_workers",
        "batch_size",
        "startup_timeout",
        "download_timeout",
        "upload_timeout",
        "upload_payload_bytes",
        "runtime_retry_count",
    ):
        if key in health:
            result[
                "health"
            ][key] = health[key]

    adaptive = _read(
        OLD_ADAPTIVE
    )

    if adaptive:
        result[
            "adaptive_health"
        ] = adaptive

        guard = adaptive.get(
            "server_guard",
            {}
        )

        if isinstance(
            guard,
            dict,
        ):

            if (
                "critical_cpu_percent"
                in guard
            ):
                result[
                    "resources"
                ][
                    "cpu_critical_percent"
                ] = guard[
                    "critical_cpu_percent"
                ]

            if (
                "max_health_xray"
                in guard
            ):
                result[
                    "resources"
                ][
                    "max_health_xray"
                ] = guard[
                    "max_health_xray"
                ]

    result[
        "meta"
    ][
        "updated_by"
    ] = "phase1-migration"

    return result


def main() -> None:

    initial = build_initial()

    obj = STORE.initialize(
        initial
    )

    print(
        "CENTRAL_SETTINGS_READY"
    )

    print(
        "schema_version=",
        obj[
            "schema_version"
        ],
    )

    print(
        "revision=",
        obj[
            "meta"
        ][
            "revision"
        ],
    )

    print(
        "path=",
        STORE.path,
    )


if __name__ == "__main__":
    main()
