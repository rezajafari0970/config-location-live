from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any


class PluginKind(str, Enum):
    INPUT_ADAPTER = "input_adapter"
    RUNTIME_BUILDER = "runtime_builder"
    DOWNLOAD_PROBE = "download_probe"
    UPLOAD_PROBE = "upload_probe"


@dataclass(frozen=True)
class RuntimeRequest:
    config_id: str
    config_type: str
    source: Any
    sandbox_dir: Path
    socks_port: int


@dataclass(frozen=True)
class RuntimeArtifact:
    config_path: Path
    socks_host: str
    socks_port: int
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ProbeRequest:
    proxy_url: str
    timeout_seconds: float
    sandbox_dir: Path


@dataclass(frozen=True)
class ProbeMeasurement:
    provider: str
    direction: str
    success: bool
    bytes_transferred: int
    duration_ms: int | None = None
    http_status: int | None = None
    error_code: str | None = None
    error_message: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
