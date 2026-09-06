from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from .types import (
    PluginKind,
    ProbeMeasurement,
    ProbeRequest,
    RuntimeArtifact,
    RuntimeRequest,
)


class Plugin(ABC):
    plugin_name: str
    plugin_version: str = "1"
    plugin_kind: PluginKind

    @abstractmethod
    def describe(self) -> dict[str, Any]:
        raise NotImplementedError


class ConfigPlugin(Plugin):
    @abstractmethod
    def supports(self, config_type: str) -> bool:
        raise NotImplementedError


class InputAdapterPlugin(ConfigPlugin):
    plugin_kind = PluginKind.INPUT_ADAPTER

    @abstractmethod
    def normalize(
        self,
        *,
        config_id: str,
        config_type: str,
        source: Any,
    ) -> Any:
        raise NotImplementedError


class RuntimeBuilderPlugin(ConfigPlugin):
    plugin_kind = PluginKind.RUNTIME_BUILDER

    @abstractmethod
    def build_runtime(
        self,
        request: RuntimeRequest,
    ) -> RuntimeArtifact:
        raise NotImplementedError


class ProbePlugin(Plugin):
    provider: str
    direction: str

    @abstractmethod
    def run(
        self,
        request: ProbeRequest,
    ) -> ProbeMeasurement:
        raise NotImplementedError


class DownloadProbePlugin(ProbePlugin):
    plugin_kind = PluginKind.DOWNLOAD_PROBE
    direction = "download"


class UploadProbePlugin(ProbePlugin):
    plugin_kind = PluginKind.UPLOAD_PROBE
    direction = "upload"
