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


# ===================================================================
# SETTINGS_FOUNDATION_V2_HARDENING
# ===================================================================
#
# SF2-01 strict unknown-key rejection
# SF2-02 corruption quarantine + fail-closed block
# SF2-03 optimistic revision / CAS writes
# SF2-04 bounded history + retention API
# SF2-05 dashboard-grade Settings status
# SF2-06 Central Settings = authoritative source of truth
# SF2-07 runtime capability map: wired vs scaffold
# SF2-08 unwired feature activation guard
#
# This section intentionally extends the existing V1 engine while
# preserving backward-compatible get/update APIs.
# ===================================================================


SETTINGS_HISTORY_KEEP = 50

SETTINGS_OPEN_DICT_PATHS = {
    (
        "adaptive_health",
    ),
}


class SettingsError(
    RuntimeError
):
    pass


class SettingsCorruptError(
    SettingsError
):
    pass


class SettingsRevisionConflictError(
    SettingsError
):
    pass


class SettingsFeatureNotWiredError(
    SettingsError
):
    pass


# -------------------------------------------------------------------
# Runtime feature truth.
#
# Conservative by design:
# only features proven by Phase 2A audit to consume Central Settings
# are marked WIRED.
# -------------------------------------------------------------------

FEATURE_RUNTIME_CONTRACTS = {
    "source_intelligence": {
        "state": "scaffold",
        "reason":
            "central schema exists; runtime source-intelligence "
            "consumer not yet wired",
    },

    "health_retest": {
        "state": "wired",
        "reason":
            "health/retest eligibility, privileged plan and worker "
            "consume Central Settings",
    },

    "config_lifetime": {
        "state": "scaffold",
        "reason":
            "central schema exists; lifecycle runtime binding pending",
    },

    "definitive_unhealthy_removal": {
        "state": "scaffold",
        "reason":
            "removal policy binding pending",
    },

    "country_remark": {
        "state": "scaffold",
        "reason":
            "country output binding pending",
    },

    "publish_country_routes": {
        "state": "scaffold",
        "reason":
            "publish runtime binding pending",
    },

    "fair_rotation": {
        "state": "scaffold",
        "reason":
            "fair rotation runtime binding pending",
    },

    "resource_guardian": {
        "state": "scaffold",
        "reason":
            "resource guardian service binding pending",
    },

    "retention_manager": {
        "state": "scaffold",
        "reason":
            "retention manager service binding pending",
    },
}


# -------------------------------------------------------------------
# Exact leaf-path runtime contracts.
#
# Every leaf not explicitly overridden below is SCaffold.
# This prevents the Panel from claiming that a stored value has an
# active runtime consumer merely because it exists in settings.json.
# -------------------------------------------------------------------

SETTING_WIRED_PATHS = {
    "features.health_retest",

    "health_retest.interval_seconds",

    "resources.cpu_warning_percent",
    "resources.cpu_critical_percent",

    "resources.ram_warning_percent",
    "resources.ram_critical_percent",

    "resources.disk_warning_percent",
    "resources.disk_critical_percent",
}


def _fsync_settings_directory(
    path: Path,
) -> None:

    fd = os.open(
        str(
            path
        ),
        os.O_RDONLY,
    )

    try:

        os.fsync(
            fd
        )

    finally:

        os.close(
            fd
        )


def _settings_block_marker(
    store,
) -> Path:

    return (
        store.root
        / "state"
        / "settings-blocked.json"
    )


def _settings_quarantine_dir(
    store,
) -> Path:

    return (
        store.root
        / "quarantine"
    )


def _settings_block_detail(
    store,
):

    marker = _settings_block_marker(
        store
    )

    if not marker.exists():

        return None


    try:

        obj = json.loads(
            marker.read_text(
                encoding="utf-8"
            )
        )

        return (
            obj
            if isinstance(
                obj,
                dict,
            )
            else {
                "blocked": True,
                "reason":
                    "invalid_block_marker",
            }
        )

    except Exception as exc:

        return {
            "blocked": True,
            "reason":
                "unreadable_block_marker",
            "error":
                type(
                    exc
                ).__name__,
        }


def _write_settings_block(
    store,
    *,
    reason: str,
    quarantine_path: Path | None,
) -> None:

    marker = _settings_block_marker(
        store
    )

    store._atomic_write(
        marker,
        {
            "blocked": True,
            "reason":
                str(
                    reason
                ),
            "blocked_at":
                _utc_now(),
            "quarantine_path":
                (
                    str(
                        quarantine_path
                    )
                    if quarantine_path
                    else None
                ),
        },
    )


def _clear_settings_block(
    store,
) -> bool:

    marker = _settings_block_marker(
        store
    )

    try:

        marker.unlink()

    except FileNotFoundError:

        return False


    _fsync_settings_directory(
        marker.parent
    )

    return True


def _quarantine_settings_file(
    store,
    *,
    reason: str,
) -> Path | None:

    path = store.path


    if not path.exists():

        _write_settings_block(
            store,
            reason=reason,
            quarantine_path=None,
        )

        return None


    quarantine = (
        _settings_quarantine_dir(
            store
        )
    )

    quarantine.mkdir(
        parents=True,
        exist_ok=True,
    )


    stamp = (
        f"{int(time.time() * 1000000)}"
        f"-{os.getpid()}"
    )


    target = (
        quarantine
        / (
            f"settings.{stamp}."
            "quarantine.json"
        )
    )


    os.replace(
        path,
        target,
    )


    _fsync_settings_directory(
        path.parent
    )

    if (
        target.parent
        != path.parent
    ):

        _fsync_settings_directory(
            target.parent
        )


    store._atomic_write(
        target.with_name(
            target.name
            + ".meta.json"
        ),
        {
            "reason":
                str(
                    reason
                ),
            "original_path":
                str(
                    path
                ),
            "quarantine_path":
                str(
                    target
                ),
            "quarantined_at":
                _utc_now(),
        },
    )


    _write_settings_block(
        store,
        reason=reason,
        quarantine_path=target,
    )


    return target


def _reject_unknown_settings_keys(
    value,
    schema,
    path=(),
) -> None:

    if path in SETTINGS_OPEN_DICT_PATHS:

        if not isinstance(
            value,
            dict,
        ):

            raise ValueError(
                ".".join(
                    path
                )
                + " must be object"
            )

        return


    if not isinstance(
        schema,
        dict,
    ):

        return


    if not isinstance(
        value,
        dict,
    ):

        return


    allowed = set(
        schema.keys()
    )


    actual = set(
        value.keys()
    )


    unknown = sorted(
        actual
        - allowed
    )


    if unknown:

        location = (
            ".".join(
                path
            )
            or "<root>"
        )

        raise ValueError(
            "unknown settings key(s) at "
            + location
            + ": "
            + ", ".join(
                unknown
            )
        )


    for key, child in value.items():

        if key not in schema:

            continue


        if (
            isinstance(
                child,
                dict,
            )
            and isinstance(
                schema[
                    key
                ],
                dict,
            )
        ):

            _reject_unknown_settings_keys(
                child,
                schema[
                    key
                ],
                path
                + (
                    str(
                        key
                    ),
                ),
            )


def _iter_setting_leaf_paths(
    value,
    prefix=(),
):

    if isinstance(
        value,
        dict,
    ):

        if not value:

            yield (
                prefix,
                value,
            )

            return


        for key, child in value.items():

            yield from _iter_setting_leaf_paths(
                child,
                prefix
                + (
                    str(
                        key
                    ),
                ),
            )

        return


    yield (
        prefix,
        value,
    )


def get_setting_runtime_contracts() -> dict:

    defaults = default_settings()

    result = {}


    for parts, _value in _iter_setting_leaf_paths(
        defaults
    ):

        if not parts:

            continue


        dotted = ".".join(
            parts
        )


        # Metadata is internal bookkeeping, not a runtime feature.
        if (
            dotted.startswith(
                "meta."
            )
            or dotted
            == "schema_version"
        ):

            state = "implemented"

        elif dotted in SETTING_WIRED_PATHS:

            state = "wired"

        else:

            state = "scaffold"


        result[
            dotted
        ] = {
            "state":
                state,
        }


    # Open legacy/adaptive subtree has storage support but is not
    # claimed as a Central Settings runtime consumer yet.
    result[
        "adaptive_health"
    ] = {
        "state":
            "scaffold",
    }


    return result


def get_feature_runtime_contracts() -> dict:

    return copy.deepcopy(
        FEATURE_RUNTIME_CONTRACTS
    )


def _enforce_feature_runtime_contract(
    obj: dict,
) -> None:

    features = obj.get(
        "features",
        {},
    )


    for key, value in features.items():

        if value is not True:

            continue


        contract = (
            FEATURE_RUNTIME_CONTRACTS.get(
                key
            )
        )


        if not contract:

            raise SettingsFeatureNotWiredError(
                "missing feature contract: "
                + str(
                    key
                )
            )


        if (
            contract.get(
                "state"
            )
            != "wired"
        ):

            raise SettingsFeatureNotWiredError(
                "feature is not wired: "
                + str(
                    key
                )
            )


# Keep the original semantic validator and harden its boundary.
_settings_v1_validate_settings = (
    validate_settings
)


def validate_settings(
    obj: dict,
) -> dict:

    _reject_unknown_settings_keys(
        obj,
        default_settings(),
    )


    result = (
        _settings_v1_validate_settings(
            obj
        )
    )


    _enforce_feature_runtime_contract(
        result
    )


    return result


def _hardened_read_unlocked(
    self,
) -> dict:

    marker = _settings_block_marker(
        self
    )


    if marker.exists():

        raise SettingsCorruptError(
            "central_settings_blocked"
        )


    if not self.path.exists():

        return default_settings()


    try:

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


    except SettingsFeatureNotWiredError:

        # A syntactically valid file containing a feature state which
        # is no longer compatible with runtime capability is still
        # unsafe as the central control plane.
        target = _quarantine_settings_file(
            self,
            reason=
                "settings_feature_contract_violation",
        )

        raise SettingsCorruptError(
            "settings_feature_contract_violation:"
            + str(
                target
            )
        )


    except (
        json.JSONDecodeError,
        UnicodeDecodeError,
        ValueError,
        OSError,
    ) as exc:

        target = _quarantine_settings_file(
            self,
            reason=(
                "settings_read_or_validation_error:"
                + type(
                    exc
                ).__name__
            ),
        )

        raise SettingsCorruptError(
            "central_settings_corrupt:"
            + str(
                target
            )
        ) from exc


def _hardened_update(
    self,
    patch: dict,
    *,
    updated_by: str = "system",
    expected_revision: int | None = None,
) -> dict:

    if not isinstance(
        patch,
        dict,
    ):

        raise ValueError(
            "settings patch must be object"
        )


    # Control-plane callers do not get to manipulate engine metadata.
    forbidden = {
        "schema_version",
        "meta",
    }


    bad = sorted(
        forbidden
        & set(
            patch.keys()
        )
    )


    if bad:

        raise ValueError(
            "reserved settings key(s): "
            + ", ".join(
                bad
            )
        )


    fd = self._lock()


    try:

        current = self._read_unlocked()


        old_revision = int(
            current.get(
                "meta",
                {}
            ).get(
                "revision",
                0,
            )
        )


        if (
            expected_revision
            is not None
            and int(
                expected_revision
            )
            != old_revision
        ):

            raise SettingsRevisionConflictError(
                "settings revision conflict: "
                f"expected={expected_revision} "
                f"actual={old_revision}"
            )


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


        self._trim_history(
            SETTINGS_HISTORY_KEEP
        )


        return copy.deepcopy(
            updated
        )


    finally:

        self._unlock(
            fd
        )


def _hardened_replace(
    self,
    obj: dict,
    *,
    updated_by: str = "system",
    expected_revision: int | None = None,
) -> dict:

    if not isinstance(
        obj,
        dict,
    ):

        raise ValueError(
            "replacement settings must be object"
        )


    fd = self._lock()


    try:

        current = self._read_unlocked()


        old_revision = int(
            current.get(
                "meta",
                {}
            ).get(
                "revision",
                0,
            )
        )


        if (
            expected_revision
            is not None
            and int(
                expected_revision
            )
            != old_revision
        ):

            raise SettingsRevisionConflictError(
                "settings revision conflict: "
                f"expected={expected_revision} "
                f"actual={old_revision}"
            )


        replacement = copy.deepcopy(
            obj
        )


        replacement[
            "schema_version"
        ] = SCHEMA_VERSION


        replacement[
            "meta"
        ] = {
            "revision":
                old_revision + 1,

            "created_at":
                (
                    current.get(
                        "meta",
                        {}
                    ).get(
                        "created_at"
                    )
                    or _utc_now()
                ),

            "updated_at":
                _utc_now(),

            "updated_by":
                str(
                    updated_by
                )[:100],
        }


        validate_settings(
            replacement
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
            replacement,
        )


        self._trim_history(
            SETTINGS_HISTORY_KEEP
        )


        return copy.deepcopy(
            replacement
        )


    finally:

        self._unlock(
            fd
        )


def _hardened_trim_history(
    self,
    keep: int = SETTINGS_HISTORY_KEEP,
) -> None:

    keep = max(
        1,
        int(
            keep
        ),
    )


    files = sorted(
        self.history.glob(
            "settings-r*.json"
        ),
        key=lambda p:
            p.stat().st_mtime,
        reverse=True,
    )


    deleted = 0


    for path in files[
        keep:
    ]:

        try:

            path.unlink()

            deleted += 1

        except FileNotFoundError:

            pass


    if deleted:

        _fsync_settings_directory(
            self.history
        )


def prune_settings_history(
    *,
    max_entries: int = SETTINGS_HISTORY_KEEP,
    max_age_days: int | None = None,
    dry_run: bool = False,
) -> dict:

    max_entries = int(
        max_entries
    )


    if max_entries < 1:

        raise ValueError(
            "max_entries must be >= 1"
        )


    if (
        max_age_days is not None
        and int(
            max_age_days
        ) < 1
    ):

        raise ValueError(
            "max_age_days must be >= 1"
        )


    fd = STORE._lock()


    try:

        files = sorted(
            STORE.history.glob(
                "settings-r*.json"
            ),
            key=lambda p:
                p.stat().st_mtime,
            reverse=True,
        )


        now = time.time()


        result = {
            "scanned":
                len(
                    files
                ),

            "eligible":
                0,

            "deleted":
                0,

            "failed":
                0,

            "dry_run":
                bool(
                    dry_run
                ),

            "max_entries":
                max_entries,

            "max_age_days":
                max_age_days,
        }


        for index, path in enumerate(
            files
        ):

            over_count = (
                index
                >= max_entries
            )


            over_age = False


            if max_age_days is not None:

                try:

                    over_age = (
                        now
                        - path.stat().st_mtime
                        >= (
                            int(
                                max_age_days
                            )
                            * 86400
                        )
                    )

                except OSError:

                    result[
                        "failed"
                    ] += 1

                    continue


            if not (
                over_count
                or over_age
            ):

                continue


            result[
                "eligible"
            ] += 1


            if dry_run:

                continue


            try:

                path.unlink()

                result[
                    "deleted"
                ] += 1

            except FileNotFoundError:

                continue

            except OSError:

                result[
                    "failed"
                ] += 1


        if (
            not dry_run
            and result[
                "deleted"
            ]
        ):

            _fsync_settings_directory(
                STORE.history
            )


        return result


    finally:

        STORE._unlock(
            fd
        )


def recover_settings_from_history(
    *,
    updated_by: str = "settings-recovery",
) -> dict:

    fd = STORE._lock()


    try:

        marker = _settings_block_marker(
            STORE
        )


        if not marker.exists():

            raise SettingsError(
                "settings store is not blocked"
            )


        candidates = sorted(
            STORE.history.glob(
                "settings-r*.json"
            ),
            key=lambda p:
                p.stat().st_mtime,
            reverse=True,
        )


        selected = None


        for path in candidates:

            try:

                obj = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )


                validate_settings(
                    obj
                )


                selected = obj

                break


            except Exception:

                continue


        if selected is None:

            raise SettingsCorruptError(
                "no_valid_settings_history"
            )


        old_revision = int(
            selected.get(
                "meta",
                {}
            ).get(
                "revision",
                0,
            )
        )


        recovered = copy.deepcopy(
            selected
        )


        recovered[
            "meta"
        ][
            "revision"
        ] = (
            old_revision
            + 1
        )


        recovered[
            "meta"
        ][
            "updated_at"
        ] = _utc_now()


        recovered[
            "meta"
        ][
            "updated_by"
        ] = str(
            updated_by
        )[:100]


        validate_settings(
            recovered
        )


        STORE._atomic_write(
            STORE.path,
            recovered,
        )


        _clear_settings_block(
            STORE
        )


        return copy.deepcopy(
            recovered
        )


    finally:

        STORE._unlock(
            fd
        )


def _hardened_status(
    self,
) -> dict:

    block = _settings_block_detail(
        self
    )


    base = {
        "path":
            str(
                self.path
            ),

        "source_of_truth":
            "central_settings",

        "legacy_inputs":
            "migration_only",

        "history_limit":
            SETTINGS_HISTORY_KEEP,

        "history_count":
            len(
                list(
                    self.history.glob(
                        "settings-r*.json"
                    )
                )
            ),

        "blocked":
            bool(
                block
            ),

        "corruption":
            block,

        "feature_contracts":
            get_feature_runtime_contracts(),

        "setting_contracts":
            get_setting_runtime_contracts(),
    }


    if block:

        base.update(
            {
                "valid":
                    False,

                "schema_version":
                    None,

                "revision":
                    None,

                "updated_at":
                    None,

                "checksum":
                    None,

                "consumer_mode":
                    "central_source_of_truth",
            }
        )

        return base


    try:

        obj = self.read()


    except SettingsCorruptError:

        block = _settings_block_detail(
            self
        )

        base[
            "blocked"
        ] = True

        base[
            "corruption"
        ] = block

        base[
            "valid"
        ] = False

        base[
            "schema_version"
        ] = None

        base[
            "revision"
        ] = None

        base[
            "updated_at"
        ] = None

        base[
            "checksum"
        ] = None

        base[
            "consumer_mode"
        ] = (
            "central_source_of_truth"
        )

        return base


    base.update(
        {
            "valid":
                True,

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

            "consumer_mode":
                "central_source_of_truth",
        }
    )


    return base


# Apply hardened methods to the existing store class/instance.
SettingsStore._read_unlocked = (
    _hardened_read_unlocked
)

SettingsStore.update = (
    _hardened_update
)

SettingsStore.replace = (
    _hardened_replace
)

SettingsStore._trim_history = (
    _hardened_trim_history
)

SettingsStore.status = (
    _hardened_status
)


# -------------------------------------------------------------------
# Public API V2
# -------------------------------------------------------------------

def get_settings() -> dict:

    return STORE.read()


def update_settings(
    patch: dict,
    *,
    updated_by: str = "system",
    expected_revision: int | None = None,
) -> dict:

    return STORE.update(
        patch,
        updated_by=updated_by,
        expected_revision=expected_revision,
    )


def replace_settings(
    obj: dict,
    *,
    updated_by: str = "system",
    expected_revision: int | None = None,
) -> dict:

    return STORE.replace(
        obj,
        updated_by=updated_by,
        expected_revision=expected_revision,
    )


def get_settings_status() -> dict:

    return STORE.status()
