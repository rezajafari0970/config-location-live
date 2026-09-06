from __future__ import annotations

import json
import os
import tempfile
import time

from pathlib import Path

import app.observability.lifecycle as o


def write(
    path: Path,
    value,
):
    path.write_text(
        json.dumps(
            value
        ),
        encoding="utf-8",
    )


def main() -> int:

    with tempfile.TemporaryDirectory() as td:

        root = Path(td)

        tracker = (
            root / "tracker.json"
        )

        policy = (
            root / "policy.json"
        )

        sync = (
            root / "sync.json"
        )

        watchdog = (
            root / "watchdog.json"
        )


        write(
            tracker,
            {
                "tracked_count": 10,
                "records": {
                    "a": {},
                    "b": {},
                },
            },
        )


        write(
            policy,
            {
                "tracked_count": 10,
                "publish_eligible": 6,
                "counts": {
                    "healthy": 5,
                    "recovered": 1,
                    "quarantine": 2,
                    "deep_quarantine": 1,
                    "error_retry": 0,
                    "unknown": 0,
                    "delete_candidate_shadow": 1,
                },
                "production_delete_enabled":
                    False,
            },
        )


        write(
            sync,
            {
                "state": "synced",
                "sync_count": 8,
                "error_count": 0,
            },
        )


        write(
            watchdog,
            {
                "evaluation": {
                    "state": "healthy",
                    "reason":
                        "lifecycle_current",
                },
                "recovery_count": 1,
                "restart_failures": 0,
                "sync_service_active": True,
            },
        )


        original = (
            o.TRACKER_PATH,
            o.POLICY_PATH,
            o.SYNC_PATH,
            o.WATCHDOG_PATH,
        )


        try:

            o.TRACKER_PATH = tracker
            o.POLICY_PATH = policy
            o.SYNC_PATH = sync
            o.WATCHDOG_PATH = watchdog


            result = (
                o.build_lifecycle_observability()
            )


            assert (
                result["state"]
                == "healthy"
            )

            assert (
                result["policy"][
                    "publish_eligible"
                ]
                == 6
            )

            assert (
                result["policy"][
                    "delete_candidate_shadow"
                ]
                == 1
            )

            assert (
                result["safety"][
                    "production_delete"
                ]
                is False
            )


            old = (
                time.time()
                - 120
            )

            os.utime(
                policy,
                (
                    old,
                    old,
                ),
            )


            stale = (
                o.build_lifecycle_observability()
            )


            assert (
                "policy_stale"
                in stale[
                    "warnings"
                ]
            )


        finally:

            (
                o.TRACKER_PATH,
                o.POLICY_PATH,
                o.SYNC_PATH,
                o.WATCHDOG_PATH,
            ) = original


    print(
        "[PASS] Lifecycle summary"
    )

    print(
        "[PASS] Policy counters"
    )

    print(
        "[PASS] Safety read-only"
    )

    print(
        "[PASS] Freshness warning"
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
