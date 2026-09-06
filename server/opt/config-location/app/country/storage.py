from __future__ import annotations

import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path

from .models import CountryResult


ROOT = Path(
    "/var/lib/config-location/"
    "country/results"
)

LATEST = ROOT / "latest"
HISTORY = ROOT / "history"


def _atomic_json(
    path: Path,
    value: dict,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    _configloc_gid = (
        __import__("grp")
        .getgrnam("configloc")
        .gr_gid
    )

    os.fchown(
        fd,
        -1,
        _configloc_gid,
    )

    os.fchmod(
        fd,
        0o640,
    )

    try:
        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.replace(tmp, path)

    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def _save_country_result_unguarded(
    result: CountryResult,
) -> tuple[Path, Path]:

    o = result.to_dict()

    stamp = datetime.now(
        timezone.utc
    ).strftime("%Y%m%dT%H%M%S.%fZ")

    latest = (
        LATEST
        / f"{result.config_id}.json"
    )

    history_dir = (
        HISTORY
        / result.config_id
    )

    history = (
        history_dir
        / f"{stamp}.json"
    )

    _atomic_json(history, o)
    _atomic_json(latest, o)

    return latest, history


# FIX22_K7_IDENTITY_WRITE_GUARD

def save_country_result(
    result,
):
    """
    Canonical Country write boundary.

    Once K6/K7 Country Identity is locked, an older
    worker is not allowed to overwrite that Country
    with ambiguous/unresolved output.
    """

    import json as _json
    from pathlib import Path as _Path

    try:
        value=result.to_dict()
    except AttributeError:
        value=dict(result)

    config_id=str(
        value.get("config_id")
        or ""
    )

    if config_id:

        identity_path=(
            _Path(
                "/var/lib/config-location/country/"
                "country-identity"
            )
            /f"{config_id}.json"
        )

        if identity_path.exists():

            try:
                identity=_json.loads(
                    identity_path.read_text()
                )
            except Exception:
                identity=None

            if (
                isinstance(identity,dict)
                and identity.get("locked") is True
                and identity.get("country_code")
            ):

                code=str(
                    identity["country_code"]
                ).upper()

                value["country_code"]=code

                if identity.get("country_name"):
                    value["country_name"]=identity[
                        "country_name"
                    ]

                if identity.get("flag"):
                    value["flag"]=identity["flag"]

                if identity.get("asn"):
                    value["asn"]=identity["asn"]

                if identity.get("network_name"):
                    value["network_name"]=identity[
                        "network_name"
                    ]

                if identity.get("network_type"):
                    value["network_type"]=identity[
                        "network_type"
                    ]

                if identity.get("country_confidence") is not None:
                    value["confidence"]=identity[
                        "country_confidence"
                    ]

                current_state=str(
                    value.get("state")
                    or ""
                )

                # Country is known. An old ambiguous/
                # unresolved result may not erase it.
                if current_state in {
                    "ambiguous",
                    "unresolved",
                }:
                    value[
                        "state"
                    ]="pending_confirmation"

                metadata=dict(
                    value.get("metadata")
                    or {}
                )

                metadata.update(
                    {
                        "country_identity_guard":
                            True,

                        "country_identity_locked":
                            True,

                        "country_detection_once":
                            True,
                    }
                )

                value["metadata"]=metadata


                class _GuardedResult:
                    def __init__(self,v):
                        self._v=v

                    def to_dict(self):
                        return dict(self._v)

                    def __getattr__(self,name):
                        try:
                            return self._v[name]
                        except KeyError as exc:
                            raise AttributeError(
                                name
                            ) from exc


                result=_GuardedResult(
                    value
                )


    return _save_country_result_unguarded(
        result
    )
