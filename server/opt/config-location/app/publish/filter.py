from __future__ import annotations

import json

from dataclasses import dataclass
from pathlib import Path
from typing import Any


CONFIG_DIR = Path(
    "/var/lib/config-location/configs"
)

POLICY_PATH = Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)


ALLOWED_STATES = {
    "healthy",
    "recovered",
}


@dataclass(frozen=True)
class PublishSnapshot:

    policy_available: bool

    total_configs: int
    policy_tracked: int

    publishable: int
    suppressed: int

    missing_policy_record: int

    configs: tuple[
        dict[str, Any],
        ...
    ]

    corrupt_configs: int = 0


def _read_json(
    path: Path,
) -> dict[str, Any] | None:

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception:
        return None


    if not isinstance(
        obj,
        dict,
    ):
        return None

    return obj


def _load_configs(
) -> tuple[
    dict[str, dict[str, Any]],
    int,
]:

    configs: dict[
        str,
        dict[str, Any],
    ] = {}

    corrupt_configs = 0


    for path in CONFIG_DIR.glob(
        "*.json"
    ):

        obj = _read_json(
            path
        )

        if obj is None:

            corrupt_configs += 1
            continue


        config_id = str(
            obj.get("id")
            or path.stem
        )


        raw = obj.get(
            "raw"
        )


        if not isinstance(
            raw,
            str,
        ):

            corrupt_configs += 1
            continue


        configs[
            config_id
        ] = obj


    return (
        configs,
        corrupt_configs,
    )


def _policy_index(
    value: dict[str, Any],
) -> dict[str, dict[str, Any]]:

    result = {}

    decisions = value.get(
        "decisions",
        [],
    )


    if not isinstance(
        decisions,
        list,
    ):
        return result


    for item in decisions:

        if not isinstance(
            item,
            dict,
        ):
            continue


        config_id = str(
            item.get(
                "config_id",
                "",
            )
        )


        if not config_id:
            continue


        result[
            config_id
        ] = item


    return result


def publishable_config_ids() -> set[str]:

    policy = _read_json(
        POLICY_PATH
    )


    if not policy:
        return set()


    index = _policy_index(
        policy
    )


    allowed = set()


    for config_id, item in (
        index.items()
    ):

        state = str(
            item.get(
                "policy_state",
                "",
            )
        ).strip().lower()


        publish_flag = bool(
            item.get(
                "publish_eligible",
                False,
            )
        )


        if (
            state in ALLOWED_STATES
            and publish_flag
        ):

            allowed.add(
                config_id
            )


    return allowed


def build_publish_snapshot(
    *,
    config_type: str | None = None,
) -> PublishSnapshot:

    (
        configs,
        corrupt_configs,
    ) = _load_configs()


    policy = _read_json(
        POLICY_PATH
    )


    kind_filter = (
        str(
            config_type
        )
        .strip()
        .lower()
        if config_type
        else None
    )


    valid_relevant = {
        config_id: record
        for config_id, record
        in configs.items()
        if (
            not kind_filter
            or str(
                record.get(
                    "type",
                    "",
                )
            ).strip().lower()
            == kind_filter
        )
    }


    # For an unfiltered snapshot, total_configs
    # represents physical config files including
    # corrupt/unreadable entries.
    #
    # For a type-filtered view a corrupt file cannot
    # safely be attributed to a protocol type, so the
    # corruption metric remains global and separate.
    total_configs = len(
        valid_relevant
    )

    if kind_filter is None:

        total_configs += (
            corrupt_configs
        )


    if not policy:

        return PublishSnapshot(
            policy_available=False,

            total_configs=total_configs,

            policy_tracked=0,

            publishable=0,

            suppressed=total_configs,

            missing_policy_record=len(
                valid_relevant
            ),

            configs=(),

            corrupt_configs=(
                corrupt_configs
            ),
        )


    policy_index = _policy_index(
        policy
    )


    output = []

    missing_policy_record = 0


    for config_id, record in (
        valid_relevant.items()
    ):

        decision = (
            policy_index.get(
                config_id
            )
        )


        if decision is None:

            missing_policy_record += 1

            # Fail closed.
            continue


        state = str(
            decision.get(
                "policy_state",
                "",
            )
        ).strip().lower()


        eligible = bool(
            decision.get(
                "publish_eligible",
                False,
            )
        )


        if (
            state not in ALLOWED_STATES
            or not eligible
        ):

            continue


        output.append(
            record
        )


    output.sort(
        key=lambda x: (
            str(
                x.get(
                    "type",
                    "",
                )
            ),
            str(
                x.get(
                    "id",
                    "",
                )
            ),
        )
    )


    return PublishSnapshot(
        policy_available=True,

        total_configs=total_configs,

        policy_tracked=len(
            policy_index
        ),

        publishable=len(
            output
        ),

        suppressed=max(
            0,
            total_configs
            - len(output),
        ),

        missing_policy_record=(
            missing_policy_record
        ),

        configs=tuple(
            output
        ),

        corrupt_configs=(
            corrupt_configs
        ),
    )
