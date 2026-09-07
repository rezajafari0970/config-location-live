from __future__ import annotations

import json
import tempfile

from pathlib import Path

from app.settings.engine import (
    SettingsCorruptError,
    SettingsFeatureNotWiredError,
    SettingsRevisionConflictError,
    SettingsStore,
    default_settings,
    get_feature_runtime_contracts,
    get_setting_runtime_contracts,
    validate_settings,
)


def main() -> None:

    with tempfile.TemporaryDirectory() as td:

        root = Path(
            td
        )


        store = SettingsStore(
            root=root / "settings",
            lock_path=root / "settings.lock",
        )


        obj = store.initialize(
            default_settings()
        )


        assert obj[
            "schema_version"
        ] == 1


        revision = obj[
            "meta"
        ][
            "revision"
        ]


        # ----------------------------------------------------
        # Unknown top-level key rejected.
        # ----------------------------------------------------

        try:

            store.update(
                {
                    "typo_section": {
                        "enabled": True
                    }
                }
            )

        except ValueError:

            pass

        else:

            raise AssertionError(
                "unknown top-level key accepted"
            )


        # ----------------------------------------------------
        # Unknown nested key rejected.
        # ----------------------------------------------------

        try:

            store.update(
                {
                    "health_retest": {
                        "interval_secondz":
                            300
                    }
                }
            )

        except ValueError:

            pass

        else:

            raise AssertionError(
                "unknown nested key accepted"
            )


        # ----------------------------------------------------
        # Scaffold feature cannot be enabled.
        # ----------------------------------------------------

        try:

            store.update(
                {
                    "features": {
                        "source_intelligence":
                            True
                    }
                }
            )

        except SettingsFeatureNotWiredError:

            pass

        else:

            raise AssertionError(
                "scaffold feature enabled"
            )


        # ----------------------------------------------------
        # Wired feature can be enabled in isolated test.
        # ----------------------------------------------------

        updated = store.update(
            {
                "features": {
                    "health_retest":
                        True
                }
            },
            expected_revision=revision,
            updated_by="selftest",
        )


        assert updated[
            "features"
        ][
            "health_retest"
        ] is True


        new_revision = updated[
            "meta"
        ][
            "revision"
        ]


        # ----------------------------------------------------
        # Stale revision rejected.
        # ----------------------------------------------------

        try:

            store.update(
                {
                    "health_retest": {
                        "interval_seconds":
                            600
                    }
                },
                expected_revision=revision,
            )

        except SettingsRevisionConflictError:

            pass

        else:

            raise AssertionError(
                "stale revision accepted"
            )


        # ----------------------------------------------------
        # Correct CAS revision accepted.
        # ----------------------------------------------------

        updated = store.update(
            {
                "health_retest": {
                    "interval_seconds":
                        600
                }
            },
            expected_revision=new_revision,
        )


        assert updated[
            "health_retest"
        ][
            "interval_seconds"
        ] == 600


        # ----------------------------------------------------
        # Runtime contract metadata.
        # ----------------------------------------------------

        features = (
            get_feature_runtime_contracts()
        )

        assert features[
            "health_retest"
        ][
            "state"
        ] == "wired"


        assert features[
            "source_intelligence"
        ][
            "state"
        ] == "scaffold"


        settings_contract = (
            get_setting_runtime_contracts()
        )


        assert settings_contract[
            "health_retest.interval_seconds"
        ][
            "state"
        ] == "wired"


        # ----------------------------------------------------
        # History bounded / trim works.
        # ----------------------------------------------------

        for _ in range(
            6
        ):

            current = store.read()

            store.update(
                {
                    "health_retest": {
                        "interval_seconds":
                            current[
                                "health_retest"
                            ][
                                "interval_seconds"
                            ]
                    }
                }
            )


        store._trim_history(
            3
        )


        assert len(
            list(
                store.history.glob(
                    "settings-r*.json"
                )
            )
        ) <= 3


        # ----------------------------------------------------
        # Corruption is fail-closed and quarantined.
        # ----------------------------------------------------

        store.update(
            {
                "health_retest": {
                    "interval_seconds":
                        900
                }
            }
        )


        store.path.write_bytes(
            b'{"broken":'
        )


        try:

            store.read()

        except SettingsCorruptError:

            pass

        else:

            raise AssertionError(
                "corrupt Settings accepted"
            )


        assert not store.path.exists()


        block = (
            store.root
            / "state"
            / "settings-blocked.json"
        )


        assert block.exists()


        status = store.status()


        assert status[
            "blocked"
        ] is True


        assert status[
            "valid"
        ] is False


    print(
        "SETTINGS_V2_SELFTEST_PASS"
    )


if __name__ == "__main__":

    main()
