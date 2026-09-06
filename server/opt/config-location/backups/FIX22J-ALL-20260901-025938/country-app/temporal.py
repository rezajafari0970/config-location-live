from __future__ import annotations

import json
import os
import tempfile

from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


OBS_ROOT=Path(
    "/var/lib/config-location/"
    "country/observations"
)


def utc_now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


@dataclass(frozen=True)
class TemporalVerdict:
    state: str
    country_code: str | None
    stable_country: bool
    stable_exit_ip: bool
    country_confidence: float
    observations: int
    unique_countries: int
    unique_exit_ips: int
    reason: str


def _atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
        suffix=".tmp",
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
            os.fsync(
                f.fileno()
            )

        os.replace(tmp,path)

    except Exception:

        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def observation_path(
    config_id: str,
) -> Path:

    return (
        OBS_ROOT
        / f"{config_id}.json"
    )


def load_observations(
    config_id: str,
) -> list[dict[str, Any]]:

    p=observation_path(
        config_id
    )

    if not p.exists():
        return []

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return []

    rows=o.get(
        "observations",
        []
    )

    if not isinstance(
        rows,
        list,
    ):
        return []

    return [
        row
        for row in rows
        if isinstance(
            row,
            dict,
        )
    ]


def append_observation(
    *,
    config_id: str,
    exit_ip: str | None,
    country_code: str | None,
    country_name: str | None,
    confidence: float,
    asn: str | None = None,
    network_type: str | None = None,
    maximum_history: int = 12,
) -> list[dict[str, Any]]:

    rows=load_observations(
        config_id
    )

    rows.append(
        {
            "observed_at":
                utc_now(),

            "exit_ip":
                exit_ip,

            "country_code":
                country_code,

            "country_name":
                country_name,

            "confidence":
                float(
                    confidence
                ),

            "asn":
                asn,

            "network_type":
                network_type,
        }
    )

    rows=rows[
        -maximum_history:
    ]

    _atomic_json(
        observation_path(
            config_id
        ),
        {
            "schema_version":1,
            "config_id":
                config_id,
            "observations":
                rows,
        },
    )

    return rows


def decide_temporal(
    observations: list[
        dict[str, Any]
    ],
    *,
    minimum_observations: int = 2,
) -> TemporalVerdict:

    usable=[
        row
        for row in observations
        if (
            row.get(
                "country_code"
            )
            and
            row.get(
                "exit_ip"
            )
        )
    ]

    if not usable:
        return TemporalVerdict(
            state="unknown",
            country_code=None,
            stable_country=False,
            stable_exit_ip=False,
            country_confidence=0.0,
            observations=0,
            unique_countries=0,
            unique_exit_ips=0,
            reason="no_usable_observations",
        )

    countries=Counter(
        str(
            row[
                "country_code"
            ]
        ).upper()
        for row in usable
    )

    ips=Counter(
        str(
            row["exit_ip"]
        )
        for row in usable
    )

    country,agreed=(
        countries.most_common(
            1
        )[0]
    )

    confidence=(
        agreed
        / len(usable)
    )

    unique_countries=len(
        countries
    )

    unique_ips=len(
        ips
    )

    if (
        len(usable)
        < minimum_observations
    ):
        return TemporalVerdict(
            state="pending_confirmation",
            country_code=country,
            stable_country=(
                unique_countries
                == 1
            ),
            stable_exit_ip=(
                unique_ips
                == 1
            ),
            country_confidence=
                confidence,
            observations=len(
                usable
            ),
            unique_countries=
                unique_countries,
            unique_exit_ips=
                unique_ips,
            reason=(
                "insufficient_temporal_observations"
            ),
        )

    if unique_countries > 1:

        return TemporalVerdict(
            state="rotating",
            country_code=None,
            stable_country=False,
            stable_exit_ip=False,
            country_confidence=
                confidence,
            observations=len(
                usable
            ),
            unique_countries=
                unique_countries,
            unique_exit_ips=
                unique_ips,
            reason=(
                "country_changed_across_observations"
            ),
        )

    if unique_ips > 1:

        return TemporalVerdict(
            state="confirmed_rotating_ip",
            country_code=country,
            stable_country=True,
            stable_exit_ip=False,
            country_confidence=1.0,
            observations=len(
                usable
            ),
            unique_countries=1,
            unique_exit_ips=
                unique_ips,
            reason=(
                "stable_country_multiple_exit_ips"
            ),
        )

    return TemporalVerdict(
        state="confirmed_stable",
        country_code=country,
        stable_country=True,
        stable_exit_ip=True,
        country_confidence=1.0,
        observations=len(
            usable
        ),
        unique_countries=1,
        unique_exit_ips=1,
        reason=(
            "stable_country_and_exit_ip"
        ),
    )
