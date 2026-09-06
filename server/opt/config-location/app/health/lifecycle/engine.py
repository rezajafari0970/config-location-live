from __future__ import annotations

import json
import os
import tempfile

from dataclasses import (
    asdict,
    dataclass,
)
from datetime import (
    datetime,
    timezone,
)
from enum import Enum
from pathlib import Path
from typing import Any


CONFIG_DIR = Path(
    "/var/lib/config-location/configs"
)

RESULT_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

STATE_ROOT = Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

LATEST_STATE = (
    STATE_ROOT / "latest.json"
)

HISTORY_DIR = (
    STATE_ROOT / "history"
)


class LifecycleState(
    str,
    Enum,
):
    NEW = "new"
    HEALTHY = "healthy"
    QUARANTINED = "quarantined"
    ERROR_RETRY = "error_retry"
    MISSING_CONFIG = "missing_config"


@dataclass(frozen=True)
class LifecycleDecision:
    config_id: str
    config_type: str

    lifecycle_state: LifecycleState

    health_state: str | None

    publish_eligible: bool
    delete_eligible: bool
    retest_required: bool

    reason: str

    source_ids: tuple[str, ...]

    last_seen_at: str | None
    health_finished_at: str | None

    error_code: str | None = None


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def _read_json(
    path: Path,
) -> dict[str, Any] | None:

    try:
        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        if isinstance(
            obj,
            dict,
        ):
            return obj

    except Exception:
        pass

    return None


def _atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp = tempfile.mkstemp(
        dir=str(
            path.parent
        ),
        prefix=(
            "."
            + path.name
            + "."
        ),
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            f.write("\n")

            f.flush()

            os.fsync(
                f.fileno()
            )

        # Preserve the destination directory group.
        # This keeps lifecycle state readable by
        # the Panel group after every atomic replace.
        parent_gid = path.parent.stat().st_gid

        os.chown(
            tmp,
            -1,
            parent_gid,
        )

        os.chmod(
            tmp,
            0o640,
        )

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(
            tmp
        ):
            os.unlink(
                tmp
            )


def decide_lifecycle(
    *,
    config: dict[str, Any] | None,
    health: dict[str, Any] | None,
    config_id: str,
) -> LifecycleDecision:

    if config is None:

        return LifecycleDecision(
            config_id=config_id,
            config_type=str(
                (
                    health
                    or {}
                ).get(
                    "config_type",
                    "unknown",
                )
            ),
            lifecycle_state=(
                LifecycleState.MISSING_CONFIG
            ),
            health_state=(
                str(
                    health.get(
                        "state"
                    )
                )
                if health
                else None
            ),
            publish_eligible=False,
            delete_eligible=False,
            retest_required=False,
            reason="config_record_missing",
            source_ids=(),
            last_seen_at=None,
            health_finished_at=(
                health.get(
                    "finished_at"
                )
                if health
                else None
            ),
            error_code=(
                health.get(
                    "error_code"
                )
                if health
                else None
            ),
        )


    config_type = str(
        config.get(
            "type",
            "unknown",
        )
    )

    sources = tuple(
        sorted(
            str(x)
            for x
            in config.get(
                "source_ids",
                [],
            )
            if str(x)
        )
    )


    if health is None:

        return LifecycleDecision(
            config_id=config_id,
            config_type=config_type,
            lifecycle_state=(
                LifecycleState.NEW
            ),
            health_state=None,
            publish_eligible=False,
            delete_eligible=False,
            retest_required=True,
            reason="health_result_missing",
            source_ids=sources,
            last_seen_at=config.get(
                "last_seen_at"
            ),
            health_finished_at=None,
        )


    state = str(
        health.get(
            "state",
            "",
        )
    ).strip().lower()


    if state == "healthy":

        return LifecycleDecision(
            config_id=config_id,
            config_type=config_type,
            lifecycle_state=(
                LifecycleState.HEALTHY
            ),
            health_state=state,
            publish_eligible=True,
            delete_eligible=False,
            retest_required=True,
            reason="latest_health_healthy",
            source_ids=sources,
            last_seen_at=config.get(
                "last_seen_at"
            ),
            health_finished_at=health.get(
                "finished_at"
            ),
            error_code=health.get(
                "error_code"
            ),
        )


    if state == "unhealthy":

        return LifecycleDecision(
            config_id=config_id,
            config_type=config_type,
            lifecycle_state=(
                LifecycleState.QUARANTINED
            ),
            health_state=state,
            publish_eligible=False,
            delete_eligible=False,
            retest_required=True,
            reason=(
                "latest_health_unhealthy_"
                "shadow_quarantine"
            ),
            source_ids=sources,
            last_seen_at=config.get(
                "last_seen_at"
            ),
            health_finished_at=health.get(
                "finished_at"
            ),
            error_code=health.get(
                "error_code"
            ),
        )


    if state == "error":

        return LifecycleDecision(
            config_id=config_id,
            config_type=config_type,
            lifecycle_state=(
                LifecycleState.ERROR_RETRY
            ),
            health_state=state,
            publish_eligible=False,
            delete_eligible=False,
            retest_required=True,
            reason=(
                "health_error_never_delete"
            ),
            source_ids=sources,
            last_seen_at=config.get(
                "last_seen_at"
            ),
            health_finished_at=health.get(
                "finished_at"
            ),
            error_code=health.get(
                "error_code"
            ),
        )


    return LifecycleDecision(
        config_id=config_id,
        config_type=config_type,
        lifecycle_state=(
            LifecycleState.ERROR_RETRY
        ),
        health_state=(
            state
            or None
        ),
        publish_eligible=False,
        delete_eligible=False,
        retest_required=True,
        reason=(
            "unknown_health_state"
        ),
        source_ids=sources,
        last_seen_at=config.get(
            "last_seen_at"
        ),
        health_finished_at=health.get(
            "finished_at"
        ),
        error_code=health.get(
            "error_code"
        ),
    )


def load_configs() -> dict[
    str,
    dict[str, Any],
]:

    result = {}

    for path in CONFIG_DIR.glob(
        "*.json"
    ):

        obj = _read_json(
            path
        )

        if not obj:
            continue

        config_id = str(
            obj.get(
                "id"
            )
            or path.stem
        )

        result[
            config_id
        ] = obj

    return result


def load_health_results() -> dict[
    str,
    dict[str, Any],
]:

    result = {}

    for path in RESULT_DIR.glob(
        "*.json"
    ):

        obj = _read_json(
            path
        )

        if not obj:
            continue

        config_id = str(
            obj.get(
                "config_id"
            )
            or path.stem
        )

        result[
            config_id
        ] = obj

    return result


def build_lifecycle_snapshot() -> dict[str, Any]:

    configs = load_configs()
    health = load_health_results()

    all_ids = sorted(
        set(configs)
        | set(health)
    )

    decisions = []

    counts = {
        state.value: 0
        for state
        in LifecycleState
    }

    publish_eligible = 0
    retest_required = 0
    delete_eligible = 0


    for config_id in all_ids:

        decision = decide_lifecycle(
            config=configs.get(
                config_id
            ),
            health=health.get(
                config_id
            ),
            config_id=config_id,
        )

        decisions.append(
            decision
        )

        counts[
            decision.lifecycle_state.value
        ] += 1

        publish_eligible += int(
            decision.publish_eligible
        )

        retest_required += int(
            decision.retest_required
        )

        delete_eligible += int(
            decision.delete_eligible
        )


    payload = {
        "schema_version": 1,

        "generated_at":
            now_iso(),

        "mode":
            "shadow",

        "production_mutation":
            False,

        "config_count":
            len(configs),

        "health_result_count":
            len(health),

        "tracked_count":
            len(decisions),

        "counts":
            counts,

        "publish_eligible":
            publish_eligible,

        "retest_required":
            retest_required,

        "delete_eligible":
            delete_eligible,

        "decisions": [
            {
                **asdict(x),
                "lifecycle_state":
                    x.lifecycle_state.value,
            }
            for x
            in decisions
        ],
    }


    STATE_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    HISTORY_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    os.chmod(
        STATE_ROOT,
        0o700,
    )

    os.chmod(
        HISTORY_DIR,
        0o700,
    )


    _atomic_json(
        LATEST_STATE,
        payload,
    )


    history_name = (
        datetime.now(
            timezone.utc
        ).strftime(
            "%Y%m%d-%H%M%S"
        )
        + ".json"
    )


    _atomic_json(
        HISTORY_DIR
        / history_name,
        payload,
    )


    return payload
