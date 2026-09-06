from __future__ import annotations

import tempfile
from pathlib import Path

from .json_store import (
    JsonHealthResultStore,
)

from ..core.models import (
    HealthResult,
    HealthState,
    ProbeResult,
)


def main() -> int:

    with tempfile.TemporaryDirectory(
        prefix="ht9-store-"
    ) as td:

        root = Path(td)

        store = (
            JsonHealthResultStore(
                root
            )
        )

        result = HealthResult(
            job_id="job-1",
            config_id="config-1",
            config_type="vless",
            state=(
                HealthState.HEALTHY
            ),
            started_at=(
                "2026-01-01T00:00:00Z"
            ),
            finished_at=(
                "2026-01-01T00:00:01Z"
            ),
            xray_started=True,
            download_verified=True,
            upload_verified=True,
            metadata={
                "health_decision": {
                    "healthy": True,
                    "reason": "healthy",
                }
            },
        )

        result.download_results.append(
            ProbeResult(
                provider="cloudflare",
                direction="download",
                success=True,
                bytes_transferred=131072,
                duration_ms=100,
            )
        )

        result.upload_results.append(
            ProbeResult(
                provider="google",
                direction="upload",
                success=True,
                bytes_transferred=65536,
                duration_ms=120,
            )
        )

        store.save(
            result
        )

        latest = store.get(
            "config-1"
        )

        history = store.get_job(
            "job-1"
        )

        assert latest is not None
        assert history is not None

        assert (
            latest.state
            == HealthState.HEALTHY
        )

        assert (
            latest.download_verified
            is True
        )

        assert (
            latest.upload_verified
            is True
        )

        assert (
            len(
                latest.download_results
            )
            == 1
        )

        assert (
            len(
                latest.upload_results
            )
            == 1
        )

        latest_file = (
            root
            / "latest"
            / "config-1.json"
        )

        history_file = (
            root
            / "history"
            / "job-1.json"
        )

        assert latest_file.exists()
        assert history_file.exists()

        assert (
            latest_file.stat().st_mode
            & 0o777
        ) == 0o600

        assert (
            history_file.stat().st_mode
            & 0o777
        ) == 0o600

        leftovers = list(
            root.rglob(
                "*.tmp"
            )
        )

        assert leftovers == []

        # Update same config with a new job.
        result2 = HealthResult(
            job_id="job-2",
            config_id="config-1",
            config_type="vless",
            state=(
                HealthState.UNHEALTHY
            ),
            xray_started=True,
        )

        store.save(
            result2
        )

        latest2 = store.get(
            "config-1"
        )

        assert latest2 is not None

        assert (
            latest2.job_id
            == "job-2"
        )

        assert (
            latest2.state
            == HealthState.UNHEALTHY
        )

        old_history = (
            store.get_job(
                "job-1"
            )
        )

        assert old_history is not None

        assert (
            old_history.state
            == HealthState.HEALTHY
        )

        print(
            "[PASS] atomic latest write"
        )

        print(
            "[PASS] immutable history write"
        )

        print(
            "[PASS] latest replacement"
        )

        print(
            "[PASS] history preserved"
        )

        print(
            "[PASS] mode 0600"
        )

        print(
            "[PASS] no temp leftovers"
        )

        print(
            "[PASS] serialization round-trip"
        )

        print(
            "[PASS] HT9 result store"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
