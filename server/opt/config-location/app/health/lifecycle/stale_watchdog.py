from __future__ import annotations

import json
import os
import signal
import subprocess
import time

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.health.lifecycle.write_control import (
    HeartbeatGate,
    atomic_json_if_changed,
)


STATE_DIR = Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

RESULT_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

POLICY_PATH = (
    STATE_DIR / "policy-latest.json"
)

TRACKER_PATH = (
    STATE_DIR / "consecutive-state.json"
)

SYNC_STATUS_PATH = (
    STATE_DIR / "sync-status.json"
)

WATCHDOG_STATUS_PATH = (
    STATE_DIR / "watchdog-status.json"
)

SYNC_SERVICE = (
    "config-location-lifecycle-sync.service"
)


CHECK_INTERVAL = 5.0
STALE_THRESHOLD = 90.0
RESTART_COOLDOWN = 120.0

STATUS_HEARTBEAT_SECONDS = 30.0


_shutdown = False

_watchdog_status_gate = HeartbeatGate(
    heartbeat_seconds=
        STATUS_HEARTBEAT_SECONDS,
)


@dataclass(frozen=True)
class Evaluation:
    state: str
    stale: bool
    restart_required: bool

    reason: str

    result_count: int
    newest_result_age_seconds: float | None

    policy_age_seconds: float | None
    tracker_age_seconds: float | None
    sync_status_age_seconds: float | None

    result_policy_lag_seconds: float | None


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def handle_signal(signum, frame) -> None:
    global _shutdown
    _shutdown = True


signal.signal(
    signal.SIGTERM,
    handle_signal,
)

signal.signal(
    signal.SIGINT,
    handle_signal,
)


def read_json(path: Path) -> dict[str, Any] | None:
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


def atomic_json(
    path: Path,
    payload: dict[str, Any],
) -> None:
    tmp = path.with_name(
        "." + path.name + ".tmp"
    )

    with tmp.open(
        "w",
        encoding="utf-8",
    ) as f:
        json.dump(
            payload,
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

    parent_gid = (
        path.parent.stat().st_gid
    )

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


def newest_result_info(
    result_dir: Path,
) -> tuple[int, float | None]:
    count = 0
    newest = None

    for path in result_dir.glob(
        "*.json"
    ):
        try:
            mtime = path.stat().st_mtime
        except FileNotFoundError:
            continue

        count += 1

        if newest is None:
            newest = mtime
        else:
            newest = max(
                newest,
                mtime,
            )

    return count, newest


def file_mtime(
    path: Path,
) -> float | None:
    try:
        return path.stat().st_mtime
    except FileNotFoundError:
        return None


def age_seconds(
    timestamp: float | None,
    *,
    now: float,
) -> float | None:
    if timestamp is None:
        return None

    return max(
        0.0,
        now - timestamp,
    )


def service_active(
    service: str,
) -> bool:
    result = subprocess.run(
        [
            "systemctl",
            "is-active",
            "--quiet",
            service,
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    return result.returncode == 0


def restart_sync() -> tuple[bool, str]:
    result = subprocess.run(
        [
            "systemctl",
            "restart",
            SYNC_SERVICE,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode == 0:
        return True, ""

    error = (
        result.stderr
        or result.stdout
        or "unknown restart error"
    )

    return (
        False,
        error[:1000],
    )


def evaluate(
    *,
    result_dir: Path = RESULT_DIR,
    policy_path: Path = POLICY_PATH,
    tracker_path: Path = TRACKER_PATH,
    sync_status_path: Path = SYNC_STATUS_PATH,
    sync_active: bool = True,
    now: float | None = None,
    stale_threshold: float = STALE_THRESHOLD,
) -> Evaluation:
    current = (
        time.time()
        if now is None
        else float(now)
    )

    result_count, newest_result = (
        newest_result_info(
            result_dir
        )
    )

    policy_mtime = file_mtime(
        policy_path
    )

    tracker_mtime = file_mtime(
        tracker_path
    )

    sync_mtime = file_mtime(
        sync_status_path
    )


    newest_result_age = age_seconds(
        newest_result,
        now=current,
    )

    policy_age = age_seconds(
        policy_mtime,
        now=current,
    )

    tracker_age = age_seconds(
        tracker_mtime,
        now=current,
    )

    sync_age = age_seconds(
        sync_mtime,
        now=current,
    )


    lag = None

    if (
        newest_result is not None
        and policy_mtime is not None
    ):
        lag = max(
            0.0,
            newest_result - policy_mtime,
        )


    if not sync_active:
        return Evaluation(
            state="recover",
            stale=True,
            restart_required=True,
            reason="sync_service_inactive",
            result_count=result_count,
            newest_result_age_seconds=
                newest_result_age,
            policy_age_seconds=policy_age,
            tracker_age_seconds=tracker_age,
            sync_status_age_seconds=sync_age,
            result_policy_lag_seconds=lag,
        )


    if policy_mtime is None:
        return Evaluation(
            state="recover",
            stale=True,
            restart_required=True,
            reason="policy_missing",
            result_count=result_count,
            newest_result_age_seconds=
                newest_result_age,
            policy_age_seconds=None,
            tracker_age_seconds=tracker_age,
            sync_status_age_seconds=sync_age,
            result_policy_lag_seconds=None,
        )


    if tracker_mtime is None:
        return Evaluation(
            state="recover",
            stale=True,
            restart_required=True,
            reason="tracker_missing",
            result_count=result_count,
            newest_result_age_seconds=
                newest_result_age,
            policy_age_seconds=policy_age,
            tracker_age_seconds=None,
            sync_status_age_seconds=sync_age,
            result_policy_lag_seconds=lag,
        )


    if sync_mtime is None:
        return Evaluation(
            state="recover",
            stale=True,
            restart_required=True,
            reason="sync_status_missing",
            result_count=result_count,
            newest_result_age_seconds=
                newest_result_age,
            policy_age_seconds=policy_age,
            tracker_age_seconds=tracker_age,
            sync_status_age_seconds=None,
            result_policy_lag_seconds=lag,
        )


    # Result Store is newer than Policy by more
    # than the permitted lag.
    if (
        lag is not None
        and lag > stale_threshold
    ):
        return Evaluation(
            state="stale",
            stale=True,
            restart_required=True,
            reason="policy_behind_results",
            result_count=result_count,
            newest_result_age_seconds=
                newest_result_age,
            policy_age_seconds=policy_age,
            tracker_age_seconds=tracker_age,
            sync_status_age_seconds=sync_age,
            result_policy_lag_seconds=lag,
        )


    # Sync status itself stopped updating.
    if (
        sync_age is not None
        and sync_age > stale_threshold
    ):
        return Evaluation(
            state="stale",
            stale=True,
            restart_required=True,
            reason="sync_status_stale",
            result_count=result_count,
            newest_result_age_seconds=
                newest_result_age,
            policy_age_seconds=policy_age,
            tracker_age_seconds=tracker_age,
            sync_status_age_seconds=sync_age,
            result_policy_lag_seconds=lag,
        )


    return Evaluation(
        state="healthy",
        stale=False,
        restart_required=False,
        reason="lifecycle_current",
        result_count=result_count,
        newest_result_age_seconds=
            newest_result_age,
        policy_age_seconds=policy_age,
        tracker_age_seconds=tracker_age,
        sync_status_age_seconds=sync_age,
        result_policy_lag_seconds=lag,
    )


def main() -> int:
    cycle = 0
    recovery_count = 0
    restart_failures = 0

    last_restart_monotonic = None

    while not _shutdown:
        cycle += 1

        sync_is_active = (
            service_active(
                SYNC_SERVICE
            )
        )

        evaluation = evaluate(
            sync_active=sync_is_active
        )


        restart_attempted = False
        restart_success = None
        restart_error = None

        cooldown_remaining = 0.0


        if evaluation.restart_required:
            allowed = True

            if (
                last_restart_monotonic
                is not None
            ):
                elapsed = (
                    time.monotonic()
                    - last_restart_monotonic
                )

                cooldown_remaining = max(
                    0.0,
                    RESTART_COOLDOWN
                    - elapsed,
                )

                if cooldown_remaining > 0:
                    allowed = False


            if allowed:
                restart_attempted = True

                ok, error = restart_sync()

                restart_success = ok

                last_restart_monotonic = (
                    time.monotonic()
                )

                if ok:
                    recovery_count += 1
                else:
                    restart_failures += 1
                    restart_error = error


        payload = {
            "schema_version": 1,
            "component":
                "lifecycle-stale-watchdog",

            "updated_at":
                now_iso(),

            "pid":
                os.getpid(),

            "cycle":
                cycle,

            "evaluation":
                asdict(
                    evaluation
                ),

            "sync_service_active":
                sync_is_active,

            "restart_attempted":
                restart_attempted,

            "restart_success":
                restart_success,

            "restart_error":
                restart_error,

            "restart_cooldown_seconds":
                RESTART_COOLDOWN,

            "cooldown_remaining_seconds":
                round(
                    cooldown_remaining,
                    3,
                ),

            "recovery_count":
                recovery_count,

            "restart_failures":
                restart_failures,

            "production_delete":
                False,

            "protected_services": [
                "config-location-panel.service",
                "config-location-fetcher.service",
                "config-location-health-adaptive.service",
            ],
        }


        semantic = {
            "evaluation":
                payload[
                    "evaluation"
                ],

            "sync_service_active":
                payload[
                    "sync_service_active"
                ],

            "restart_attempted":
                payload[
                    "restart_attempted"
                ],

            "restart_success":
                payload[
                    "restart_success"
                ],

            "recovery_count":
                payload[
                    "recovery_count"
                ],

            "restart_failures":
                payload[
                    "restart_failures"
                ],
        }


        should_write, reason = (
            _watchdog_status_gate.should_write(
                semantic
            )
        )


        if should_write:

            payload[
                "write_reason"
            ] = reason

            atomic_json_if_changed(
                WATCHDOG_STATUS_PATH,
                payload,
            )


        end = (
            time.monotonic()
            + CHECK_INTERVAL
        )

        while (
            not _shutdown
            and time.monotonic() < end
        ):
            time.sleep(
                min(
                    0.5,
                    max(
                        0.0,
                        end
                        - time.monotonic(),
                    ),
                )
            )


    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
