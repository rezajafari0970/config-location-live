from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .base import HealthResultStore
from ..core.models import (
    HealthResult,
    HealthState,
    ProbeResult,
)


class JsonHealthResultStore(
    HealthResultStore
):
    def __init__(
        self,
        root: Path = Path(
            "/var/lib/config-location/"
            "health-results"
        ),
    ) -> None:

        self.root = root

        self.latest_dir = (
            root / "latest"
        )

        self.history_dir = (
            root / "history"
        )

        self.latest_dir.mkdir(
            parents=True,
            exist_ok=True,
        )

        self.history_dir.mkdir(
            parents=True,
            exist_ok=True,
        )

        os.chmod(
            self.root,
            0o700,
        )

        os.chmod(
            self.latest_dir,
            0o700,
        )

        os.chmod(
            self.history_dir,
            0o700,
        )

    @staticmethod
    def _safe_name(
        value: str,
    ) -> str:

        safe = "".join(
            c
            if c.isalnum()
            or c in "._-"
            else "_"
            for c in value
        )

        safe = safe[:160]

        if not safe:
            raise ValueError(
                "empty safe filename"
            )

        return safe

    @staticmethod
    def _probe_to_dict(
        probe: ProbeResult,
    ) -> dict[str, Any]:

        return {
            "provider":
                probe.provider,

            "direction":
                probe.direction,

            "success":
                probe.success,

            "bytes_transferred":
                probe.bytes_transferred,

            "duration_ms":
                probe.duration_ms,

            "error":
                probe.error,

            "metadata":
                probe.metadata,
        }

    @classmethod
    def _result_to_dict(
        cls,
        result: HealthResult,
    ) -> dict[str, Any]:

        return {
            "schema_version": 1,

            "job_id":
                result.job_id,

            "config_id":
                result.config_id,

            "config_type":
                result.config_type,

            "state":
                result.state.value,

            "started_at":
                result.started_at,

            "finished_at":
                result.finished_at,

            "xray_started":
                result.xray_started,

            "xray_exit_code":
                result.xray_exit_code,

            "download_verified":
                result.download_verified,

            "upload_verified":
                result.upload_verified,

            "download_results": [
                cls._probe_to_dict(p)
                for p
                in result.download_results
            ],

            "upload_results": [
                cls._probe_to_dict(p)
                for p
                in result.upload_results
            ],

            "error_code":
                result.error_code,

            "error_message":
                result.error_message,

            "metadata":
                result.metadata,
        }

    @staticmethod
    def _probe_from_dict(
        value: dict[str, Any],
    ) -> ProbeResult:

        return ProbeResult(
            provider=str(
                value.get(
                    "provider",
                    "",
                )
            ),

            direction=str(
                value.get(
                    "direction",
                    "",
                )
            ),

            success=bool(
                value.get(
                    "success",
                    False,
                )
            ),

            bytes_transferred=int(
                value.get(
                    "bytes_transferred",
                    0,
                )
                or 0
            ),

            duration_ms=(
                int(
                    value[
                        "duration_ms"
                    ]
                )
                if value.get(
                    "duration_ms"
                )
                is not None
                else None
            ),

            error=(
                str(
                    value[
                        "error"
                    ]
                )
                if value.get(
                    "error"
                )
                is not None
                else None
            ),

            metadata=dict(
                value.get(
                    "metadata",
                    {},
                )
                or {}
            ),
        )

    @classmethod
    def _result_from_dict(
        cls,
        value: dict[str, Any],
    ) -> HealthResult:

        state = HealthState(
            value["state"]
        )

        result = HealthResult(
            job_id=str(
                value["job_id"]
            ),

            config_id=str(
                value["config_id"]
            ),

            config_type=str(
                value["config_type"]
            ),

            state=state,

            started_at=value.get(
                "started_at"
            ),

            finished_at=value.get(
                "finished_at"
            ),

            xray_started=bool(
                value.get(
                    "xray_started",
                    False,
                )
            ),

            xray_exit_code=(
                int(
                    value[
                        "xray_exit_code"
                    ]
                )
                if value.get(
                    "xray_exit_code"
                )
                is not None
                else None
            ),

            download_verified=bool(
                value.get(
                    "download_verified",
                    False,
                )
            ),

            upload_verified=bool(
                value.get(
                    "upload_verified",
                    False,
                )
            ),

            error_code=value.get(
                "error_code"
            ),

            error_message=value.get(
                "error_message"
            ),

            metadata=dict(
                value.get(
                    "metadata",
                    {},
                )
                or {}
            ),
        )

        result.download_results = [
            cls._probe_from_dict(x)
            for x
            in value.get(
                "download_results",
                [],
            )
        ]

        result.upload_results = [
            cls._probe_from_dict(x)
            for x
            in value.get(
                "upload_results",
                [],
            )
        ]

        return result

    @staticmethod
    def _atomic_write_json(
        path: Path,
        value: dict[str, Any],
    ) -> None:

        path.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        fd, tmp_name = (
            tempfile.mkstemp(
                prefix=(
                    "."
                    + path.name
                    + "."
                ),
                suffix=".tmp",
                dir=str(
                    path.parent
                ),
            )
        )

        tmp = Path(
            tmp_name
        )

        try:
            with os.fdopen(
                fd,
                "w",
                encoding="utf-8",
            ) as fh:

                json.dump(
                    value,
                    fh,
                    ensure_ascii=False,
                    separators=(
                        ",",
                        ":",
                    ),
                    sort_keys=True,
                )

                fh.write(
                    "\n"
                )

                fh.flush()

                os.fsync(
                    fh.fileno()
                )

            os.chmod(
                tmp,
                0o600,
            )

            os.replace(
                tmp,
                path,
            )

            dir_fd = os.open(
                str(
                    path.parent
                ),
                os.O_DIRECTORY,
            )

            try:
                os.fsync(
                    dir_fd
                )
            finally:
                os.close(
                    dir_fd
                )

        finally:
            if tmp.exists():
                tmp.unlink(
                    missing_ok=True
                )

    def save(
        self,
        result: HealthResult,
    ) -> None:

        payload = (
            self._result_to_dict(
                result
            )
        )

        config_name = (
            self._safe_name(
                result.config_id
            )
        )

        job_name = (
            self._safe_name(
                result.job_id
            )
        )

        latest_path = (
            self.latest_dir
            / f"{config_name}.json"
        )

        history_path = (
            self.history_dir
            / f"{job_name}.json"
        )

        # History first, then latest pointer.
        self._atomic_write_json(
            history_path,
            payload,
        )

        self._atomic_write_json(
            latest_path,
            payload,
        )

    def get(
        self,
        config_id: str,
    ) -> HealthResult | None:

        name = self._safe_name(
            config_id
        )

        path = (
            self.latest_dir
            / f"{name}.json"
        )

        if not path.exists():
            return None

        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        return (
            self._result_from_dict(
                value
            )
        )

    def get_job(
        self,
        job_id: str,
    ) -> HealthResult | None:

        name = self._safe_name(
            job_id
        )

        path = (
            self.history_dir
            / f"{name}.json"
        )

        if not path.exists():
            return None

        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        return (
            self._result_from_dict(
                value
            )
        )
