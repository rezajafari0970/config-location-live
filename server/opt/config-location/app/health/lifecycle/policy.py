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

from app.health.lifecycle.write_control import (
    atomic_json_if_changed,
)


TRACKER_PATH = Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "consecutive-state.json"
)

POLICY_STATE_PATH = Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)


class PolicyState(
    str,
    Enum,
):
    HEALTHY = "healthy"
    QUARANTINE = "quarantine"
    DEEP_QUARANTINE = "deep_quarantine"
    ERROR_RETRY = "error_retry"
    RECOVERED = "recovered"
    UNKNOWN = "unknown"
    DELETE_CANDIDATE_SHADOW = (
        "delete_candidate_shadow"
    )


@dataclass(frozen=True)
class PolicyConfig:
    deep_quarantine_after_unhealthy: int = 2
    delete_candidate_after_unhealthy: int = 4
    healthy_recovery_immediate: bool = True
    error_never_delete: bool = True
    production_delete_enabled: bool = False


@dataclass(frozen=True)
class PolicyDecision:
    config_id: str
    policy_state: PolicyState

    publish_eligible: bool
    quarantine: bool
    deep_quarantine: bool
    retry_required: bool

    delete_candidate_shadow: bool
    production_delete_allowed: bool

    consecutive_healthy: int
    consecutive_unhealthy: int
    consecutive_error: int

    reason: str

    last_result_state: str | None
    last_result_finished_at: str | None
    last_healthy_at: str | None
    quarantine_started_at: str | None


def now_iso() -> str:

    return datetime.now(
        timezone.utc
    ).isoformat()


def _read_json(
    path: Path,
) -> dict[str, Any]:

    value = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    if not isinstance(
        value,
        dict,
    ):
        raise ValueError(
            f"{path} must contain object"
        )

    return value


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
        prefix="."
        + path.name
        + ".",
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


def decide_policy(
    record: dict[str, Any],
    *,
    config: PolicyConfig | None = None,
) -> PolicyDecision:

    cfg = config or PolicyConfig()

    config_id = str(
        record.get(
            "config_id",
            "",
        )
    )

    if not config_id:
        raise ValueError(
            "tracker record missing config_id"
        )

    h = int(
        record.get(
            "consecutive_healthy",
            0,
        )
    )

    u = int(
        record.get(
            "consecutive_unhealthy",
            0,
        )
    )

    e = int(
        record.get(
            "consecutive_error",
            0,
        )
    )

    state = str(
        record.get(
            "last_result_state"
        )
        or ""
    ).strip().lower()

    previous_had_quarantine = bool(
        record.get(
            "quarantine_started_at"
        )
    )

    last_healthy_at = record.get(
        "last_healthy_at"
    )

    finished = record.get(
        "last_result_finished_at"
    )

    quarantine_started_at = record.get(
        "quarantine_started_at"
    )


    if state == "healthy":

        recovered = (
            cfg.healthy_recovery_immediate
            and h >= 1
            and (
                record.get(
                    "last_unhealthy_at"
                )
                is not None
                or record.get(
                    "last_error_at"
                )
                is not None
            )
        )

        return PolicyDecision(
            config_id=config_id,
            policy_state=(
                PolicyState.RECOVERED
                if recovered
                else PolicyState.HEALTHY
            ),
            publish_eligible=True,
            quarantine=False,
            deep_quarantine=False,
            retry_required=True,
            delete_candidate_shadow=False,
            production_delete_allowed=False,
            consecutive_healthy=h,
            consecutive_unhealthy=u,
            consecutive_error=e,
            reason=(
                "healthy_recovered_immediately"
                if recovered
                else "healthy_publish"
            ),
            last_result_state=state,
            last_result_finished_at=finished,
            last_healthy_at=last_healthy_at,
            quarantine_started_at=None,
        )


    if state == "unhealthy":

        if (
            u
            >= cfg.delete_candidate_after_unhealthy
        ):

            return PolicyDecision(
                config_id=config_id,
                policy_state=(
                    PolicyState.DELETE_CANDIDATE_SHADOW
                ),
                publish_eligible=False,
                quarantine=True,
                deep_quarantine=True,
                retry_required=True,
                delete_candidate_shadow=True,
                production_delete_allowed=False,
                consecutive_healthy=h,
                consecutive_unhealthy=u,
                consecutive_error=e,
                reason=(
                    "unhealthy_threshold_reached_"
                    "shadow_only"
                ),
                last_result_state=state,
                last_result_finished_at=finished,
                last_healthy_at=last_healthy_at,
                quarantine_started_at=(
                    quarantine_started_at
                ),
            )


        if (
            u
            >= cfg.deep_quarantine_after_unhealthy
        ):

            return PolicyDecision(
                config_id=config_id,
                policy_state=(
                    PolicyState.DEEP_QUARANTINE
                ),
                publish_eligible=False,
                quarantine=True,
                deep_quarantine=True,
                retry_required=True,
                delete_candidate_shadow=False,
                production_delete_allowed=False,
                consecutive_healthy=h,
                consecutive_unhealthy=u,
                consecutive_error=e,
                reason=(
                    "consecutive_unhealthy_"
                    "deep_quarantine"
                ),
                last_result_state=state,
                last_result_finished_at=finished,
                last_healthy_at=last_healthy_at,
                quarantine_started_at=(
                    quarantine_started_at
                ),
            )


        return PolicyDecision(
            config_id=config_id,
            policy_state=(
                PolicyState.QUARANTINE
            ),
            publish_eligible=False,
            quarantine=True,
            deep_quarantine=False,
            retry_required=True,
            delete_candidate_shadow=False,
            production_delete_allowed=False,
            consecutive_healthy=h,
            consecutive_unhealthy=u,
            consecutive_error=e,
            reason="single_unhealthy_quarantine",
            last_result_state=state,
            last_result_finished_at=finished,
            last_healthy_at=last_healthy_at,
            quarantine_started_at=(
                quarantine_started_at
            ),
        )


    if state in (
        "error",
        "unknown",
    ):

        return PolicyDecision(
            config_id=config_id,
            policy_state=(
                PolicyState.ERROR_RETRY
            ),
            publish_eligible=False,
            quarantine=False,
            deep_quarantine=False,
            retry_required=True,
            delete_candidate_shadow=False,
            production_delete_allowed=False,
            consecutive_healthy=h,
            consecutive_unhealthy=u,
            consecutive_error=e,
            reason=(
                "runtime_or_infra_error_retry_only"
            ),
            last_result_state=state,
            last_result_finished_at=finished,
            last_healthy_at=last_healthy_at,
            quarantine_started_at=None,
        )


    return PolicyDecision(
        config_id=config_id,
        policy_state=(
            PolicyState.UNKNOWN
        ),
        publish_eligible=False,
        quarantine=False,
        deep_quarantine=False,
        retry_required=True,
        delete_candidate_shadow=False,
        production_delete_allowed=False,
        consecutive_healthy=h,
        consecutive_unhealthy=u,
        consecutive_error=e,
        reason="unknown_tracker_state",
        last_result_state=(
            state
            or None
        ),
        last_result_finished_at=finished,
        last_healthy_at=last_healthy_at,
        quarantine_started_at=(
            quarantine_started_at
        ),
    )


def build_policy_snapshot(
    *,
    config: PolicyConfig | None = None,
) -> dict[str, Any]:

    cfg = config or PolicyConfig()

    tracker = _read_json(
        TRACKER_PATH
    )

    records = tracker.get(
        "records",
        {},
    )

    if not isinstance(
        records,
        dict,
    ):
        raise ValueError(
            "tracker records must be object"
        )

    decisions: list[
        PolicyDecision
    ] = []

    counts = {
        state.value: 0
        for state
        in PolicyState
    }

    publish_eligible = 0
    quarantine_count = 0
    deep_quarantine_count = 0
    delete_candidate_shadow_count = 0


    for config_id in sorted(
        records
    ):

        record = records[
            config_id
        ]

        decision = decide_policy(
            record,
            config=cfg,
        )

        decisions.append(
            decision
        )

        counts[
            decision.policy_state.value
        ] += 1

        publish_eligible += int(
            decision.publish_eligible
        )

        quarantine_count += int(
            decision.quarantine
        )

        deep_quarantine_count += int(
            decision.deep_quarantine
        )

        delete_candidate_shadow_count += int(
            decision.delete_candidate_shadow
        )


    payload = {
        "schema_version": 1,

        "generated_at":
            now_iso(),

        "mode":
            "shadow",

        "production_delete_enabled":
            cfg.production_delete_enabled,

        "policy": {
            "deep_quarantine_after_unhealthy":
                cfg.deep_quarantine_after_unhealthy,

            "delete_candidate_after_unhealthy":
                cfg.delete_candidate_after_unhealthy,

            "healthy_recovery_immediate":
                cfg.healthy_recovery_immediate,

            "error_never_delete":
                cfg.error_never_delete,
        },

        "tracked_count":
            len(decisions),

        "counts":
            counts,

        "publish_eligible":
            publish_eligible,

        "quarantine_count":
            quarantine_count,

        "deep_quarantine_count":
            deep_quarantine_count,

        "delete_candidate_shadow_count":
            delete_candidate_shadow_count,

        "production_delete_allowed_count":
            0,

        "decisions": [
            {
                **asdict(
                    decision
                ),
                "policy_state":
                    decision.policy_state.value,
            }
            for decision
            in decisions
        ],
    }


    write_performed = atomic_json_if_changed(
        POLICY_STATE_PATH,
        payload,
    )

    payload[
        "write_performed"
    ] = write_performed


    return payload
