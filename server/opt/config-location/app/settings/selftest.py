from __future__ import annotations

import tempfile

from pathlib import Path

from app.settings.engine import (
    SettingsStore,
    default_settings,
)


def main() -> None:

    with tempfile.TemporaryDirectory() as td:

        root = Path(td)

        store = SettingsStore(
            root=root / "settings",
            lock_path=root / "settings.lock",
        )

        obj = store.initialize(
            default_settings()
        )

        assert (
            obj["schema_version"]
            == 1
        )

        before = obj[
            "meta"
        ][
            "revision"
        ]

        updated = store.update(
            {
                "health_retest": {
                    "interval_seconds":
                        1200
                },

                "source_intelligence": {
                    "healthy_window_hours":
                        24
                },
            },
            updated_by="selftest",
        )

        assert (
            updated[
                "health_retest"
            ][
                "interval_seconds"
            ]
            == 1200
        )

        assert (
            updated[
                "source_intelligence"
            ][
                "healthy_window_hours"
            ]
            == 24
        )

        assert (
            updated[
                "meta"
            ][
                "revision"
            ]
            == before + 1
        )

        assert len(
            store.checksum(
                updated
            )
        ) == 64

        try:
            store.update(
                {
                    "resources": {
                        "disk_warning_percent":
                            99,

                        "disk_critical_percent":
                            90,
                    }
                }
            )

        except ValueError:
            pass

        else:
            raise AssertionError(
                "invalid thresholds accepted"
            )

    print(
        "SETTINGS_SELFTEST_PASS"
    )


if __name__ == "__main__":
    main()
