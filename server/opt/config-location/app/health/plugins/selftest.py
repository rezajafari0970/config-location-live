from pathlib import Path

from .base import (
    DownloadProbePlugin,
    RuntimeBuilderPlugin,
    UploadProbePlugin,
)
from .registry import PluginRegistry
from .types import (
    PluginKind,
    ProbeMeasurement,
    ProbeRequest,
    RuntimeArtifact,
    RuntimeRequest,
)


class DummyRuntime(RuntimeBuilderPlugin):
    plugin_name = "dummy-runtime"

    def describe(self):
        return {"name": self.plugin_name}

    def supports(self, config_type):
        return config_type == "vless"

    def build_runtime(self, request):
        return RuntimeArtifact(
            config_path=request.sandbox_dir / "config.json",
            socks_host="127.0.0.1",
            socks_port=request.socks_port,
        )


class DummyDownload(DownloadProbePlugin):
    plugin_name = "dummy-download"
    provider = "dummy"

    def describe(self):
        return {"provider": self.provider}

    def run(self, request):
        return ProbeMeasurement(
            provider=self.provider,
            direction=self.direction,
            success=True,
            bytes_transferred=1024,
        )


class DummyUpload(UploadProbePlugin):
    plugin_name = "dummy-upload"
    provider = "dummy"

    def describe(self):
        return {"provider": self.provider}

    def run(self, request):
        return ProbeMeasurement(
            provider=self.provider,
            direction=self.direction,
            success=True,
            bytes_transferred=1024,
        )


def main():
    registry = PluginRegistry()

    registry.load([
        DummyRuntime(),
        DummyDownload(),
        DummyUpload(),
    ])

    assert len(registry.all()) == 3

    runtime_plugins = registry.supporting(
        PluginKind.RUNTIME_BUILDER,
        "vless",
    )

    assert len(runtime_plugins) == 1

    assert len(
        registry.by_kind(
            PluginKind.DOWNLOAD_PROBE
        )
    ) == 1

    assert len(
        registry.by_kind(
            PluginKind.UPLOAD_PROBE
        )
    ) == 1

    runtime = runtime_plugins[0].build_runtime(
        RuntimeRequest(
            config_id="test",
            config_type="vless",
            source="dummy",
            sandbox_dir=Path("/tmp/unused"),
            socks_port=12345,
        )
    )

    assert runtime.socks_port == 12345

    request = ProbeRequest(
        proxy_url="socks5h://127.0.0.1:12345",
        timeout_seconds=1,
        sandbox_dir=Path("/tmp/unused"),
    )

    download = registry.by_kind(
        PluginKind.DOWNLOAD_PROBE
    )[0].run(request)

    upload = registry.by_kind(
        PluginKind.UPLOAD_PROBE
    )[0].run(request)

    assert download.success
    assert upload.success
    assert download.bytes_transferred > 0
    assert upload.bytes_transferred > 0

    try:
        registry.register(DummyRuntime())
    except ValueError:
        pass
    else:
        raise AssertionError(
            "duplicate plugin accepted"
        )

    print("[PASS] strict plugin kinds")
    print("[PASS] runtime contract")
    print("[PASS] download probe contract")
    print("[PASS] upload probe contract")
    print("[PASS] registry duplicate protection")
    print("[PASS] config-type selection")
    print("[PASS] HT2 plugin contracts")


if __name__ == "__main__":
    main()
