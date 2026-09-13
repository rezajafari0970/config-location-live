#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

D=/var/lib/config-location/country
OBS="$D/observations"

mkdir -p "$OBS"

cat >"$M/temporal.py" <<'PY'
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
PY


cat >"$M/selftest_temporal.py" <<'PY'
from __future__ import annotations

from .temporal import (
    decide_temporal,
)


def row(
    ip: str,
    country: str,
) -> dict:

    return {
        "exit_ip":ip,
        "country_code":country,
    }


def main() -> int:

    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            )
        ]
    )

    assert (
        r.state
        ==
        "pending_confirmation"
    )

    print(
        "[PASS] one observation pending"
    )


    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            ),
            row(
                "1.1.1.1",
                "DE",
            ),
        ]
    )

    assert (
        r.state
        ==
        "confirmed_stable"
    )

    print(
        "[PASS] stable country + IP"
    )


    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            ),
            row(
                "2.2.2.2",
                "DE",
            ),
        ]
    )

    assert (
        r.state
        ==
        "confirmed_rotating_ip"
    )

    assert (
        r.country_code
        == "DE"
    )

    print(
        "[PASS] rotating IP same country"
    )


    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            ),
            row(
                "2.2.2.2",
                "US",
            ),
        ]
    )

    assert (
        r.state
        == "rotating"
    )

    assert (
        r.country_code
        is None
    )

    print(
        "[PASS] rotating country detected"
    )


    print(
        "[PASS] FIX22E temporal engine"
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/temporal.py" \
"$M/selftest_temporal.py"

echo "COMPILE=PASS"


echo "=== 2. SELFTEST ==="

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_temporal

echo "SELFTEST=PASS"


echo "=== 3. REAL EXIT TEMPORAL STORAGE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.temporal import (
    append_observation,
    decide_temporal,
)

CID="FIX22E-SELFTEST"

rows=append_observation(
    config_id=CID,
    exit_ip="91.107.184.117",
    country_code="DE",
    country_name="Germany",
    confidence=1.0,
    asn="AS24940",
    network_type="hosting",
)

r=decide_temporal(
    rows
)

print(
    "OBS1_STATE=",
    r.state,
)

assert (
    r.state
    ==
    "pending_confirmation"
)


rows=append_observation(
    config_id=CID,
    exit_ip="91.107.184.117",
    country_code="DE",
    country_name="Germany",
    confidence=1.0,
    asn="AS24940",
    network_type="hosting",
)

r=decide_temporal(
    rows
)

print(
    "OBS2_STATE=",
    r.state,
)

print(
    "COUNTRY=",
    r.country_code,
)

print(
    "STABLE_COUNTRY=",
    r.stable_country,
)

print(
    "STABLE_EXIT_IP=",
    r.stable_exit_ip,
)

assert (
    r.state
    ==
    "confirmed_stable"
)

assert (
    r.country_code
    == "DE"
)

print(
    "TEMPORAL_STORAGE=PASS"
)
PY


rm -f \
"$OBS/FIX22E-SELFTEST.json"


echo "=== 4. SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


echo "========================================"
echo "FIX22E=PASS"
echo "TEMPORAL_CONFIRMATION=READY"
echo "STABLE_EXIT_DETECTION=READY"
echo "ROTATING_IP_DETECTION=READY"
echo "ROTATING_COUNTRY_DETECTION=READY"
echo "MAX_OBSERVATION_HISTORY=12"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
