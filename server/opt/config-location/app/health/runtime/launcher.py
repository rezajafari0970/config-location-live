from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .sandbox import XraySandbox
from .xray_capability import (
    classify_xray_capability,
)
from .validation import (
    classify_xray_validation_output,
)
from .builders.uri_xray import UriXrayRuntimeBuilder
from .builders.xray_json import XrayJsonRuntimeBuilder
from .builders.wireguard_xray import (
    WireGuardXrayRuntimeBuilder,
)
from ..plugins.types import RuntimeRequest

from app.xray_log_retention import (
    archive_xray_run,
)

# FIX22_POSTK_XRAY_FORENSIC_RETENTION


class RuntimeLaunchError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "runtime_launch_failed",
        source_invalid: bool = False,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.source_invalid = source_invalid
        self.retryable = retryable


@dataclass
class RunningRuntime:
    sandbox: XraySandbox
    config_id: str
    config_type: str
    metadata: dict[str, Any]

    @property
    def socks_port(self) -> int:
        if self.sandbox.socks_port is None:
            raise RuntimeLaunchError(
                "SOCKS port unavailable"
            )
        return self.sandbox.socks_port

    @property
    def proxy_url(self) -> str:
        return (
            f"socks5h://127.0.0.1:"
            f"{self.socks_port}"
        )

    @property
    def pid(self) -> int:
        process = self.sandbox.process

        if process is None:
            raise RuntimeLaunchError(
                "Xray process unavailable"
            )

        return process.pid

    def stop(self) -> None:
        self.sandbox.cleanup()


class RuntimeLauncher:

    def __init__(
        self,
        *,
        base_dir: Path = Path(
            "/var/lib/config-location/"
            "health-sandboxes"
        ),
        xray_binary: Path = Path(
            "/usr/local/bin/xray"
        ),
    ) -> None:

        self.base_dir = base_dir
        self.xray_binary = xray_binary

        self.uri_builder = (
            UriXrayRuntimeBuilder()
        )

        self.json_builder = (
            XrayJsonRuntimeBuilder()
        )

        self.wireguard_builder = (
            WireGuardXrayRuntimeBuilder()
        )

    def _builder(
        self,
        config_type: str,
    ):
        kind = config_type.strip().lower()

        if self.uri_builder.supports(kind):
            return self.uri_builder

        if self.json_builder.supports(kind):
            return self.json_builder

        if self.wireguard_builder.supports(kind):
            return self.wireguard_builder

        raise RuntimeLaunchError(
            f"unsupported config type: {kind}",
            code="unsupported_config_type",
            source_invalid=False,
            retryable=False,
        )

    def launch(
        self,
        *,
        config_id: str,
        config_type: str,
        source: Any,
        startup_timeout: float = 6.0,
    ) -> RunningRuntime:

        decision = (
            classify_xray_capability(
                config_type,
                source,
            )
        )

        if not decision.supported:

            raise RuntimeLaunchError(
                decision.reason,

                code=
                    decision.status,

                source_invalid=(
                    decision.status
                    ==
                    "invalid"
                ),

                retryable=False,
            )

        sandbox = XraySandbox(
            base_dir=self.base_dir,
            xray_binary=self.xray_binary,
            config_id=config_id,
        )

        # Forensic state from the SAME Xray execution.
        # No second Xray process is ever started.
        validation_stdout = ""
        validation_stderr = ""
        validation_returncode = None
        failure_stage = "sandbox_create"
        artifact = None

        try:
            sandbox.create()

            if sandbox.socks_port is None:
                raise RuntimeLaunchError(
                    "port allocation failed"
                )

            builder = self._builder(
                config_type
            )

            failure_stage = "runtime_build"

            artifact = builder.build_runtime(
                RuntimeRequest(
                    config_id=config_id,
                    config_type=config_type,
                    source=source,
                    sandbox_dir=(
                        sandbox.paths.root
                    ),
                    socks_port=(
                        sandbox.socks_port
                    ),
                )
            )

            # Builder and sandbox must agree on
            # the exact isolated config path.
            if (
                artifact.config_path
                != sandbox.paths.config
            ):
                raise RuntimeLaunchError(
                    "runtime path mismatch"
                )

            # Validate before starting a real
            # process. No proxy traffic occurs.
            failure_stage = "xray_validation"

            result = subprocess.run(
                [
                    str(self.xray_binary),
                    "run",
                    "-test",
                    "-c",
                    str(
                        artifact.config_path
                    ),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )

            validation_stdout = (
                result.stdout or ""
            )

            validation_stderr = (
                result.stderr or ""
            )

            validation_returncode = (
                result.returncode
            )

            if result.returncode != 0:

                classification = (
                    classify_xray_validation_output(
                        result.stdout,
                        result.stderr,
                    )
                )

                raise RuntimeLaunchError(
                    (
                        "xray config validation failed: "
                        + classification.code
                    ),
                    code=classification.code,
                    source_invalid=(
                        classification.source_invalid
                    ),
                    retryable=(
                        classification.retryable
                    ),
                )

            failure_stage = "xray_runtime_start"

            sandbox.start()

            failure_stage = "xray_runtime_readiness"

            if not sandbox.wait_started(
                timeout=startup_timeout
            ):
                raise RuntimeLaunchError(
                    "xray SOCKS listener "
                    "did not become ready"
                )

            return RunningRuntime(
                sandbox=sandbox,
                config_id=config_id,
                config_type=config_type,
                metadata=dict(
                    artifact.metadata
                ),
            )

        except Exception as exc:

            # IMPORTANT:
            # archive before sandbox.cleanup(), because
            # cleanup recursively removes runtime.json
            # and the real Xray stdout/stderr logs.
            try:

                runtime_stdout = ""
                runtime_stderr = ""

                if sandbox.paths.stdout.exists():
                    runtime_stdout = (
                        sandbox.paths.stdout.read_text(
                            encoding="utf-8",
                            errors="replace",
                        )
                    )

                if sandbox.paths.stderr.exists():
                    runtime_stderr = (
                        sandbox.paths.stderr.read_text(
                            encoding="utf-8",
                            errors="replace",
                        )
                    )


                combined_stdout = (
                    "===== XRAY VALIDATION STDOUT =====\n"
                    + validation_stdout
                    + "\n"
                    "===== XRAY RUNTIME STDOUT =====\n"
                    + runtime_stdout
                )

                combined_stderr = (
                    "===== XRAY VALIDATION STDERR =====\n"
                    + validation_stderr
                    + "\n"
                    "===== XRAY RUNTIME STDERR =====\n"
                    + runtime_stderr
                )


                # Preserve source.raw exactly as received
                # whenever it can be represented without
                # altering bytes/string contents.
                source_raw = source

                if not isinstance(
                    source_raw,
                    (str, bytes),
                ):
                    try:
                        import json as _json

                        source_raw = _json.dumps(
                            source_raw,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                    except Exception:
                        source_raw = repr(
                            source_raw
                        )


                runtime_path = None

                if (
                    artifact is not None
                    and getattr(
                        artifact,
                        "config_path",
                        None,
                    ) is not None
                ):
                    runtime_path = (
                        artifact.config_path
                    )

                elif sandbox.paths.config.exists():
                    runtime_path = (
                        sandbox.paths.config
                    )


                process_returncode = None

                if sandbox.process is not None:
                    process_returncode = (
                        sandbox.process.poll()
                    )


                archive_returncode = (
                    validation_returncode
                )

                if (
                    archive_returncode in (
                        None,
                        0,
                    )
                    and process_returncode
                    is not None
                ):
                    archive_returncode = (
                        process_returncode
                    )

                # A launcher exception is always a failed
                # forensic run even when Xray itself has
                # not yet returned a non-zero code.
                if archive_returncode in (
                    None,
                    0,
                ):
                    archive_returncode = -1


                archive_xray_run(
                    config_id=config_id,

                    stdout=combined_stdout,

                    stderr=combined_stderr,

                    returncode=archive_returncode,

                    runtime_path=runtime_path,

                    source_raw=source_raw,

                    stage=failure_stage,

                    metadata={
                        "config_type":
                            config_type,

                        "exception_type":
                            type(exc).__name__,

                        "exception_message":
                            str(exc),

                        "validation_returncode":
                            validation_returncode,

                        "runtime_returncode":
                            process_returncode,

                        "sandbox_root":
                            str(
                                sandbox.paths.root
                            ),

                        "xray_binary":
                            str(
                                self.xray_binary
                            ),

                        "second_xray":
                            False,
                    },
                )

            except Exception as archive_exc:

                # Retention must never alter the original
                # Health result or hide the real exception.
                try:
                    import sys

                    print(
                        "XRAY_FORENSIC_ARCHIVE_ERROR="
                        f"{type(archive_exc).__name__}: "
                        f"{archive_exc}",
                        file=sys.stderr,
                    )
                except Exception:
                    pass


            sandbox.cleanup()

            raise
