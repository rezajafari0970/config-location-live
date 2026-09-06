from __future__ import annotations

import copy
import fcntl
import hashlib
import json
import os
import tempfile
import time

from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1

DEFAULT_ROOT = Path(
    "/var/lib/config-location/settings"
)

DEFAULT_LOCK = Path(
    "/run/config-location/settings.lock"
)


def _utc_now() -> str:
    return time.strftime(
        "%Y-%m-%dT%H:%M:%SZ",
        time.gmtime(),
    )


def _deep_merge(
    base: dict,
    patch: dict,
) -> dict:

    result = copy.deepcopy(base)

    for key, value in patch.items():

        if (
            isinstance(value, dict)
            and isinstance(
                result.get(key),
                dict,
            )
        ):
            result[key] = _deep_merge(
                result[key],
                value,
            )
        else:
            result[key] = copy.deepcopy(
                value
            )

    return result


def _require_bool(
    value: Any,
    name: str,
) -> bool:

    if type(value) is not bool:
        raise ValueError(
            f"{name} must be boolean"
        )

    return value


def _require_int(
    value: Any,
    name: str,
    minimum: int,
    maximum: int,
) -> int:

    if type(value) is not int:
        raise ValueError(
            f"{name} must be integer"
        )

    if not minimum <= value <= maximum:
        raise ValueError(
            f"{name} must be "
            f"{minimum}..{maximum}"
        )

    return value


def _require_float(
    value: Any,
    name: str,
    minimum: float,
    maximum: float,
) -> float:

    if (
        type(value) not in {
            int,
            float,
        }
        or type(value) is bool
    ):
        raise ValueError(
            f"{name} must be number"
        )

    value = float(value)

    if not minimum <= value <= maximum:
        raise ValueError(
            f"{name} must be "
            f"{minimum}..{maximum}"
        )

    return value


def _require_str(
    value: Any,
    name: str,
    max_length: int = 200,
) -> str:

    if not isinstance(
        value,
        str,
    ):
        raise ValueError(
            f"{name} must be string"
        )

    value = value.strip()

    if len(value) > max_length:
        raise ValueError(
            f"{name} is too long"
        )

    return value


def default_settings() -> dict:

    return {
        "schema_version": SCHEMA_VERSION,

        "meta": {
            "revision": 1,
            "created_at": _utc_now(),
            "updated_at": _utc_now(),
            "updated_by": "bootstrap",
        },

        "features": {
            "source_intelligence": False,
            "health_retest": False,
            "config_lifetime": False,
            "definitive_unhealthy_removal": False,
            "country_remark": False,
            "publish_country_routes": False,
            "fair_rotation": False,
            "resource_guardian": False,
            "retention_manager": False,
        },

        "source_intelligence": {
            "healthy_window_hours": 12,
            "minimum_tested_configs": 1,
            "dashboard_alerts": True,
        },

        "health_retest": {
            "interval_seconds": 300,
            "minimum_interval_seconds": 60,
            "maximum_interval_seconds": 86400,
        },

        "config_lifetime": {
            "max_age_hours": 48,
        },

        "removal": {
            "remove_definitive_unhealthy": True,
            "remove_infrastructure_errors": False,
            "preserve_forensic_record": True,
        },

        "country": {
            "canonical_language": "en",
            "unknown_name": "Unknown",
            "unknown_flag": "❓",
            "remark_format": "{flag} {country}",
            "use_official_short_name": True,
        },

        "publish": {
            "panel_port": 4040,
            "public_port": 80,
            "country_routes": True,
            "protocol_routes": True,
            "fair_rotation_default_ed": 0,
            "preserve_original_raw": True,
            "remark_transform_on_output": True,
        },

        "cleanup": {
            "default_retention_days": 7,
            "audit_retention_days": 7,
            "devlog_retention_days": 7,
            "temporary_retention_days": 7,
            "failed_xray_retention_days": 14,
            "successful_xray_retention_days": 3,
        },

        "resources": {
            "cpu_warning_percent": 75.0,
            "cpu_critical_percent": 94.0,

            "ram_warning_percent": 80.0,
            "ram_critical_percent": 92.0,

            "disk_warning_percent": 75.0,
            "disk_critical_percent": 90.0,

            "inode_warning_percent": 75.0,
            "inode_critical_percent": 90.0,

            "max_health_xray": 200,
        },

        "fetcher": {
            "enabled": True,
            "global_concurrency": 12,
            "connect_timeout_seconds": 8,
            "read_timeout_seconds": 15,
            "total_timeout_seconds": 30,
            "max_response_bytes": 10485760,
            "max_redirects": 5,
        },

        "health": {
            "max_workers": 50,
            "batch_size": 1000,

            "startup_timeout": 6.0,
            "download_timeout": 6.0,
            "upload_timeout": 6.0,

            "upload_payload_bytes": 65536,
            "runtime_retry_count": 3,
        },

        "adaptive_health": {},
    }


def validate_settings(
    obj: dict,
) -> dict:

    if not isinstance(
        obj,
        dict,
    ):
        raise ValueError(
            "settings root must be object"
        )

    if obj.get(
        "schema_version"
    ) != SCHEMA_VERSION:
        raise ValueError(
            "unsupported schema_version"
        )

    features = obj.get(
        "features"
    )

    if not isinstance(
        features,
        dict,
    ):
        raise ValueError(
            "features must be object"
        )

    for key in (
        "source_intelligence",
        "health_retest",
        "config_lifetime",
        "definitive_unhealthy_removal",
        "country_remark",
        "publish_country_routes",
        "fair_rotation",
        "resource_guardian",
        "retention_manager",
    ):
        _require_bool(
            features.get(key),
            f"features.{key}",
        )

    src = obj[
        "source_intelligence"
    ]

    _require_int(
        src[
            "healthy_window_hours"
        ],
        "source_intelligence."
        "healthy_window_hours",
        1,
        720,
    )

    _require_int(
        src[
            "minimum_tested_configs"
        ],
        "source_intelligence."
        "minimum_tested_configs",
        1,
        100000,
    )

    _require_bool(
        src[
            "dashboard_alerts"
        ],
        "source_intelligence."
        "dashboard_alerts",
    )

    retest = obj[
        "health_retest"
    ]

    interval = _require_int(
        retest[
            "interval_seconds"
        ],
        "health_retest."
        "interval_seconds",
        60,
        86400,
    )

    minimum = _require_int(
        retest[
            "minimum_interval_seconds"
        ],
        "health_retest."
        "minimum_interval_seconds",
        30,
        86400,
    )

    maximum = _require_int(
        retest[
            "maximum_interval_seconds"
        ],
        "health_retest."
        "maximum_interval_seconds",
        60,
        604800,
    )

    if not (
        minimum
        <= interval
        <= maximum
    ):
        raise ValueError(
            "health_retest interval "
            "outside configured limits"
        )

    lifetime = obj[
        "config_lifetime"
    ]

    _require_int(
        lifetime[
            "max_age_hours"
        ],
        "config_lifetime."
        "max_age_hours",
        1,
        8760,
    )

    removal = obj[
        "removal"
    ]

    for key in (
        "remove_definitive_unhealthy",
        "remove_infrastructure_errors",
        "preserve_forensic_record",
    ):
        _require_bool(
            removal[key],
            f"removal.{key}",
        )

    country = obj[
        "country"
    ]

    _require_str(
        country[
            "canonical_language"
        ],
        "country.canonical_language",
        10,
    )

    _require_str(
        country[
            "unknown_name"
        ],
        "country.unknown_name",
        100,
    )

    _require_str(
        country[
            "unknown_flag"
        ],
        "country.unknown_flag",
        20,
    )

    remark_format = _require_str(
        country[
            "remark_format"
        ],
        "country.remark_format",
        200,
    )

    if (
        "{country}"
        not in remark_format
    ):
        raise ValueError(
            "country.remark_format "
            "must contain {country}"
        )

    _require_bool(
        country[
            "use_official_short_name"
        ],
        "country."
        "use_official_short_name",
    )

    publish = obj[
        "publish"
    ]

    _require_int(
        publish["panel_port"],
        "publish.panel_port",
        1,
        65535,
    )

    _require_int(
        publish["public_port"],
        "publish.public_port",
        1,
        65535,
    )

    _require_bool(
        publish[
            "country_routes"
        ],
        "publish.country_routes",
    )

    _require_bool(
        publish[
            "protocol_routes"
        ],
        "publish.protocol_routes",
    )

    _require_int(
        publish[
            "fair_rotation_default_ed"
        ],
        "publish."
        "fair_rotation_default_ed",
        0,
        10000,
    )

    _require_bool(
        publish[
            "preserve_original_raw"
        ],
        "publish."
        "preserve_original_raw",
    )

    _require_bool(
        publish[
            "remark_transform_on_output"
        ],
        "publish."
        "remark_transform_on_output",
    )

    cleanup = obj[
        "cleanup"
    ]

    for key in (
        "default_retention_days",
        "audit_retention_days",
        "devlog_retention_days",
        "temporary_retention_days",
        "failed_xray_retention_days",
        "successful_xray_retention_days",
    ):
        _require_int(
            cleanup[key],
            f"cleanup.{key}",
            1,
            3650,
        )

    resources = obj[
        "resources"
    ]

    for key in (
        "cpu_warning_percent",
        "cpu_critical_percent",
        "ram_warning_percent",
        "ram_critical_percent",
        "disk_warning_percent",
        "disk_critical_percent",
        "inode_warning_percent",
        "inode_critical_percent",
    ):
        _require_float(
            resources[key],
            f"resources.{key}",
            1.0,
            100.0,
        )

    for prefix in (
        "cpu",
        "ram",
        "disk",
        "inode",
    ):
        if (
            float(
                resources[
                    f"{prefix}_warning_percent"
                ]
            )
            >=
            float(
                resources[
                    f"{prefix}_critical_percent"
                ]
            )
        ):
            raise ValueError(
                f"{prefix} warning "
                "must be below critical"
            )

    _require_int(
        resources[
            "max_health_xray"
        ],
        "resources.max_health_xray",
        1,
        10000,
    )

    fetcher = obj[
        "fetcher"
    ]

    _require_bool(
        fetcher["enabled"],
        "fetcher.enabled",
    )

    _require_int(
        fetcher[
            "global_concurrency"
        ],
        "fetcher."
        "global_concurrency",
        1,
        1000,
    )

    for key in (
        "connect_timeout_seconds",
        "read_timeout_seconds",
        "total_timeout_seconds",
    ):
        _require_int(
            fetcher[key],
            f"fetcher.{key}",
            1,
            600,
        )

    _require_int(
        fetcher[
            "max_response_bytes"
        ],
        "fetcher."
        "max_response_bytes",
        1024,
        1024 * 1024 * 1024,
    )

    _require_int(
        fetcher[
            "max_redirects"
        ],
        "fetcher.max_redirects",
        0,
        50,
    )

    health = obj[
        "health"
    ]

    _require_int(
        health["max_workers"],
        "health.max_workers",
        1,
        1000,
    )

    _require_int(
        health["batch_size"],
        "health.batch_size",
        1,
        100000,
    )

    for key in (
        "startup_timeout",
        "download_timeout",
        "upload_timeout",
    ):
        _require_float(
            health[key],
            f"health.{key}",
            1.0,
            600.0,
        )

    _require_int(
        health[
            "upload_payload_bytes"
        ],
        "health."
        "upload_payload_bytes",
        1,
        100 * 1024 * 1024,
    )

    _require_int(
        health[
            "runtime_retry_count"
        ],
        "health."
        "runtime_retry_count",
        0,
        20,
    )

    if not isinstance(
        obj.get(
            "adaptive_health"
        ),
        dict,
    ):
        raise ValueError(
            "adaptive_health "
            "must be object"
        )

    return obj


class SettingsStore:

    def __init__(
        self,
        root: Path = DEFAULT_ROOT,
        lock_path: Path = DEFAULT_LOCK,
    ):

        self.root = Path(root)
        self.path = (
            self.root
            / "settings.json"
        )

        self.history = (
            self.root
            / "history"
        )

        self.lock_path = Path(
            lock_path
        )

    def ensure_dirs(self) -> None:

        self.root.mkdir(
            parents=True,
            exist_ok=True,
        )

        self.history.mkdir(
            parents=True,
            exist_ok=True,
        )

        self.lock_path.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

    def _lock(self):

        self.ensure_dirs()

        fd = os.open(
            self.lock_path,
            os.O_RDWR
            | os.O_CREAT,
            0o600,
        )

        fcntl.flock(
            fd,
            fcntl.LOCK_EX,
        )

        return fd

    def _unlock(
        self,
        fd: int,
    ) -> None:

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_UN,
            )
        finally:
            os.close(fd)

    def _atomic_write(
        self,
        path: Path,
        obj: dict,
    ) -> None:

        path.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=str(path.parent),
        )

        tmp = Path(tmp_name)

        try:
            with os.fdopen(
                fd,
                "w",
                encoding="utf-8",
            ) as handle:

                json.dump(
                    obj,
                    handle,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )

                handle.write("\n")

                handle.flush()
                os.fsync(
                    handle.fileno()
                )

            os.chmod(
                tmp,
                0o640,
            )

            os.replace(
                tmp,
                path,
            )

            dir_fd = os.open(
                path.parent,
                os.O_RDONLY,
            )

            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)

        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except FileNotFoundError:
                    pass

    def _read_unlocked(
        self,
    ) -> dict:

        if not self.path.exists():
            return default_settings()

        with self.path.open(
            "r",
            encoding="utf-8",
        ) as handle:

            obj = json.load(
                handle
            )

        return validate_settings(
            obj
        )

    def read(self) -> dict:

        fd = self._lock()

        try:
            return copy.deepcopy(
                self._read_unlocked()
            )
        finally:
            self._unlock(fd)

    def initialize(
        self,
        initial: dict | None = None,
    ) -> dict:

        fd = self._lock()

        try:
            if self.path.exists():
                return copy.deepcopy(
                    self._read_unlocked()
                )

            obj = (
                copy.deepcopy(initial)
                if initial is not None
                else default_settings()
            )

            validate_settings(obj)

            self._atomic_write(
                self.path,
                obj,
            )

            return copy.deepcopy(
                obj
            )

        finally:
            self._unlock(fd)

    def update(
        self,
        patch: dict,
        *,
        updated_by: str = "system",
    ) -> dict:

        if not isinstance(
            patch,
            dict,
        ):
            raise ValueError(
                "settings patch "
                "must be object"
            )

        fd = self._lock()

        try:
            current = self._read_unlocked()

            updated = _deep_merge(
                current,
                patch,
            )

            updated[
                "schema_version"
            ] = SCHEMA_VERSION

            meta = updated.setdefault(
                "meta",
                {}
            )

            old_revision = int(
                current.get(
                    "meta",
                    {}
                ).get(
                    "revision",
                    0,
                )
            )

            meta[
                "revision"
            ] = old_revision + 1

            meta[
                "created_at"
            ] = (
                current.get(
                    "meta",
                    {}
                ).get(
                    "created_at"
                )
                or _utc_now()
            )

            meta[
                "updated_at"
            ] = _utc_now()

            meta[
                "updated_by"
            ] = str(
                updated_by
            )[:100]

            validate_settings(
                updated
            )

            if self.path.exists():

                history_name = (
                    f"settings-r"
                    f"{old_revision:08d}-"
                    f"{int(time.time())}.json"
                )

                self._atomic_write(
                    self.history
                    / history_name,
                    current,
                )

            self._atomic_write(
                self.path,
                updated,
            )

            self._trim_history()

            return copy.deepcopy(
                updated
            )

        finally:
            self._unlock(fd)

    def replace(
        self,
        obj: dict,
        *,
        updated_by: str = "system",
    ) -> dict:

        current = self.read()

        replacement = copy.deepcopy(
            obj
        )

        replacement[
            "schema_version"
        ] = SCHEMA_VERSION

        replacement.setdefault(
            "meta",
            {}
        )

        replacement[
            "meta"
        ][
            "created_at"
        ] = current.get(
            "meta",
            {}
        ).get(
            "created_at",
            _utc_now(),
        )

        replacement[
            "meta"
        ][
            "revision"
        ] = current.get(
            "meta",
            {}
        ).get(
            "revision",
            0,
        )

        return self.update(
            replacement,
            updated_by=updated_by,
        )

    def checksum(
        self,
        obj: dict | None = None,
    ) -> str:

        if obj is None:
            obj = self.read()

        raw = json.dumps(
            obj,
            ensure_ascii=False,
            sort_keys=True,
            separators=(
                ",",
                ":",
            ),
        ).encode(
            "utf-8"
        )

        return hashlib.sha256(
            raw
        ).hexdigest()

    def status(self) -> dict:

        obj = self.read()

        return {
            "schema_version":
                obj[
                    "schema_version"
                ],

            "revision":
                obj.get(
                    "meta",
                    {}
                ).get(
                    "revision"
                ),

            "updated_at":
                obj.get(
                    "meta",
                    {}
                ).get(
                    "updated_at"
                ),

            "checksum":
                self.checksum(
                    obj
                ),

            "path":
                str(
                    self.path
                ),

            "history_count":
                len(
                    list(
                        self.history.glob(
                            "settings-r*.json"
                        )
                    )
                ),

            "consumer_mode":
                "foundation_only",
        }

    def _trim_history(
        self,
        keep: int = 50,
    ) -> None:

        files = sorted(
            self.history.glob(
                "settings-r*.json"
            ),
            key=lambda p:
                p.stat().st_mtime,
            reverse=True,
        )

        for path in files[keep:]:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


STORE = SettingsStore()


def get_settings() -> dict:
    return STORE.read()


def update_settings(
    patch: dict,
    *,
    updated_by: str = "system",
) -> dict:

    return STORE.update(
        patch,
        updated_by=updated_by,
    )


def get_settings_status() -> dict:
    return STORE.status()
