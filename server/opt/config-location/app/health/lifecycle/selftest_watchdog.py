from __future__ import annotations

import os
import tempfile
import time

from pathlib import Path

from .stale_watchdog import evaluate


def touch_at(
    path: Path,
    timestamp: float,
) -> None:
    path.write_text(
        "{}\n",
        encoding="utf-8",
    )

    os.utime(
        path,
        (
            timestamp,
            timestamp,
        ),
    )


def main() -> int:
    with tempfile.TemporaryDirectory(
        prefix="ht18.6-"
    ) as td:
        root = Path(td)

        results = root / "results"
        results.mkdir()

        policy = root / "policy.json"
        tracker = root / "tracker.json"
        status = root / "status.json"

        now = time.time()

        touch_at(
            results / "a.json",
            now - 2,
        )

        touch_at(
            policy,
            now - 1,
        )

        touch_at(
            tracker,
            now - 1,
        )

        touch_at(
            status,
            now - 1,
        )


        healthy = evaluate(
            result_dir=results,
            policy_path=policy,
            tracker_path=tracker,
            sync_status_path=status,
            sync_active=True,
            now=now,
            stale_threshold=90,
        )

        assert healthy.state == "healthy"
        assert healthy.restart_required is False


        inactive = evaluate(
            result_dir=results,
            policy_path=policy,
            tracker_path=tracker,
            sync_status_path=status,
            sync_active=False,
            now=now,
            stale_threshold=90,
        )

        assert inactive.restart_required is True
        assert inactive.reason == "sync_service_inactive"


        touch_at(
            results / "b.json",
            now,
        )

        touch_at(
            policy,
            now - 120,
        )

        stale = evaluate(
            result_dir=results,
            policy_path=policy,
            tracker_path=tracker,
            sync_status_path=status,
            sync_active=True,
            now=now,
            stale_threshold=90,
        )

        assert stale.state == "stale"
        assert stale.restart_required is True
        assert stale.reason == "policy_behind_results"


        touch_at(
            policy,
            now,
        )

        touch_at(
            status,
            now - 120,
        )

        stale_status = evaluate(
            result_dir=results,
            policy_path=policy,
            tracker_path=tracker,
            sync_status_path=status,
            sync_active=True,
            now=now,
            stale_threshold=90,
        )

        assert stale_status.restart_required is True
        assert stale_status.reason == "sync_status_stale"


        missing = root / "missing-policy.json"

        missing_policy = evaluate(
            result_dir=results,
            policy_path=missing,
            tracker_path=tracker,
            sync_status_path=status,
            sync_active=True,
            now=now,
            stale_threshold=90,
        )

        assert missing_policy.restart_required is True
        assert missing_policy.reason == "policy_missing"


    print(
        "[PASS] current state -> healthy"
    )

    print(
        "[PASS] inactive Sync -> recover"
    )

    print(
        "[PASS] Policy lag -> stale"
    )

    print(
        "[PASS] stale Sync status -> recover"
    )

    print(
        "[PASS] missing Policy -> recover"
    )

    print(
        "[PASS] HT18.6 watchdog logic"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
