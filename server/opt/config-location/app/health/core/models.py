from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class HealthState(str, Enum):
    NEW = "new"
    QUEUED = "queued"
    RUNNING = "running"
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy"
    ERROR = "error"
    RUNTIME_FAILED = "runtime_failed"
    UNSUPPORTED_BY_XRAY = "unsupported_by_xray"
    UNSUPPORTED_BY_XRAY_VERSION = "unsupported_by_xray_version"
    INVALID = "invalid"
    NOT_TESTED = "not_tested"


@dataclass(frozen=True)
class HealthJob:
    job_id: str
    config_id: str
    config_type: str
    created_at: str = field(default_factory=utc_now)
    attempt: int = 1
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ProbeResult:
    provider: str
    direction: str
    success: bool
    bytes_transferred: int = 0
    duration_ms: int | None = None
    error: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class HealthResult:
    job_id: str
    config_id: str
    config_type: str
    state: HealthState

    started_at: str | None = None
    finished_at: str | None = None

    xray_started: bool = False
    xray_exit_code: int | None = None

    download_verified: bool = False
    upload_verified: bool = False

    download_results: list[ProbeResult] = field(default_factory=list)
    upload_results: list[ProbeResult] = field(default_factory=list)

    error_code: str | None = None
    error_message: str | None = None

    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def healthy(self) -> bool:
        return (
            self.state == HealthState.HEALTHY
            and self.xray_started
            and self.download_verified
            and self.upload_verified
        )
