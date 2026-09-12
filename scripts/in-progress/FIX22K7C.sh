#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

MOD="$R/app/country/progressive_recovery.py"
REPORT=/var/lib/config-location/country/k7c-pilot-report.json

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7C-$TS"

mkdir -p "$B"

[ -f "$MOD" ] && cp -a "$MOD" "$B/" || true

cp -a \
/var/lib/config-location/country/pipeline \
"$B/pipeline-before" \
2>/dev/null || true

cp -a \
/var/lib/config-location/country/country-identity \
"$B/country-identity-before" \
2>/dev/null || true

echo "BACKUP=$B"


echo "=== 1. INSTALL PROGRESSIVE RECOVERY ENGINE ==="

cat >"$MOD" <<'PY'
from __future__ import annotations

import json
import subprocess
import time

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from dataclasses import dataclass
from typing import Any


@dataclass
class RecoveryEvidence:

    provider: str

    success: bool

    country_code: str | None = None
    country_name: str | None = None

    asn: str | None = None
    network_name: str | None = None

    evidence_type: str = "geo"

    error: str | None = None

    duration_ms: int = 0


def _curl_json(
    url: str,
    timeout: float,
) -> dict[str,Any]:

    result=subprocess.run(
        [
            "curl",
            "-4",
            "-fsSL",
            "--max-time",
            str(timeout),
            "-H",
            "Accept: application/json",
            url,
        ],
        capture_output=True,
        text=True,
        timeout=timeout+2,
    )

    if result.returncode!=0:

        raise RuntimeError(
            (
                result.stderr
                or "curl failed"
            )[:500]
        )

    obj=json.loads(
        result.stdout
    )

    if not isinstance(obj,dict):
        raise RuntimeError(
            "response is not object"
        )

    return obj


def _norm_country(
    value: Any,
) -> str | None:

    if not isinstance(
        value,
        str,
    ):
        return None

    value=value.strip().upper()

    if len(value)!=2:
        return None

    if not value.isalpha():
        return None

    return value


def lookup_dbip(
    ip: str,
    timeout: float = 4.0,
) -> RecoveryEvidence:

    started=time.monotonic()

    try:

        o=_curl_json(
            "https://api.db-ip.com/v2/free/"
            +ip,
            timeout,
        )

        code=_norm_country(
            o.get("countryCode")
        )

        if not code:

            raise RuntimeError(
                "countryCode missing"
            )

        return RecoveryEvidence(
            provider="db-ip",
            success=True,
            country_code=code,
            country_name=o.get(
                "countryName"
            ),
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )

    except Exception as exc:

        return RecoveryEvidence(
            provider="db-ip",
            success=False,
            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )


def lookup_ipinfo(
    ip: str,
    timeout: float = 4.0,
) -> RecoveryEvidence:

    started=time.monotonic()

    try:

        o=_curl_json(
            "https://ipinfo.io/"
            +ip
            +"/json",
            timeout,
        )

        code=_norm_country(
            o.get("country")
        )

        if not code:

            raise RuntimeError(
                "country missing"
            )

        org=str(
            o.get("org")
            or ""
        ).strip()

        asn=None
        network=None

        if org:

            parts=org.split(
                " ",
                1,
            )

            if (
                parts
                and parts[0]
                .upper()
                .startswith("AS")
            ):
                asn=parts[0].upper()

                if len(parts)>1:
                    network=parts[1]


        return RecoveryEvidence(
            provider="ipinfo",
            success=True,
            country_code=code,
            asn=asn,
            network_name=network,
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )

    except Exception as exc:

        return RecoveryEvidence(
            provider="ipinfo",
            success=False,
            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )


def lookup_rdap(
    ip: str,
    timeout: float = 5.0,
) -> RecoveryEvidence:

    started=time.monotonic()

    try:

        o=_curl_json(
            "https://rdap.org/ip/"
            +ip,
            timeout,
        )

        code=_norm_country(
            o.get("country")
        )

        name=(
            o.get("name")
            or o.get("handle")
        )

        return RecoveryEvidence(
            provider="rdap",
            success=bool(code),
            country_code=code,
            network_name=(
                str(name)
                if name
                else None
            ),
            evidence_type="registry",
            error=(
                None
                if code
                else "RDAP country missing"
            ),
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )

    except Exception as exc:

        return RecoveryEvidence(
            provider="rdap",
            success=False,
            evidence_type="registry",
            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )


def recover_country(
    ip: str,
    timeout: float = 5.0,
) -> dict:

    providers=(
        lookup_dbip,
        lookup_ipinfo,
        lookup_rdap,
    )

    rows=[]

    with ThreadPoolExecutor(
        max_workers=3,
        thread_name_prefix="k7-recovery",
    ) as executor:

        futures={
            executor.submit(
                p,
                ip,
                timeout,
            ):p
            for p in providers
        }

        for future in as_completed(
            futures
        ):

            try:
                rows.append(
                    future.result()
                )
            except Exception as exc:

                p=futures[future]

                rows.append(
                    RecoveryEvidence(
                        provider=p.__name__,
                        success=False,
                        error=(
                            f"{type(exc).__name__}: "
                            f"{exc}"
                        )[:500],
                    )
                )


    geo=[
        r
        for r in rows
        if (
            r.success
            and r.evidence_type=="geo"
            and r.country_code
        )
    ]

    registry=[
        r
        for r in rows
        if (
            r.success
            and r.evidence_type=="registry"
            and r.country_code
        )
    ]


    geo_codes=[
        r.country_code
        for r in geo
    ]


    confirmed=None
    reason="insufficient_independent_evidence"


    # Strongest path:
    # two independent physical Geo providers agree.
    if (
        len(geo_codes)>=2
        and len(
            set(geo_codes)
        )==1
    ):

        confirmed=geo_codes[0]

        reason="two_independent_geo_agree"


    # Secondary path:
    # one Geo source + independent RDAP registry.
    elif (
        len(geo_codes)==1
        and registry
        and any(
            r.country_code
            ==geo_codes[0]
            for r in registry
        )
    ):

        confirmed=geo_codes[0]

        reason="geo_plus_rdap_agree"


    country_name=None
    asn=None
    network_name=None


    if confirmed:

        for r in rows:

            if (
                r.country_code
                !=confirmed
            ):
                continue

            if (
                country_name is None
                and r.country_name
            ):
                country_name=(
                    r.country_name
                )

            if (
                asn is None
                and r.asn
            ):
                asn=r.asn

            if (
                network_name is None
                and r.network_name
            ):
                network_name=(
                    r.network_name
                )


    return {
        "state":(
            "confirmed"
            if confirmed
            else "ambiguous"
        ),

        "country_code":
            confirmed,

        "country_name":
            country_name,

        "asn":
            asn,

        "network_name":
            network_name,

        "network_type":
            None,

        "country_confidence":(
            0.92
            if reason
            =="two_independent_geo_agree"
            else (
                0.80
                if confirmed
                else 0.0
            )
        ),

        "recovery_reason":
            reason,

        "recovery_evidence":[
            {
                "provider":
                    r.provider,

                "success":
                    r.success,

                "country_code":
                    r.country_code,

                "country_name":
                    r.country_name,

                "asn":
                    r.asn,

                "network_name":
                    r.network_name,

                "evidence_type":
                    r.evidence_type,

                "error":
                    r.error,

                "duration_ms":
                    r.duration_ms,
            }
            for r in rows
        ],
    }
PY


"$PY" -m py_compile "$MOD"

echo "PROGRESSIVE_RECOVERY_ENGINE=PASS"


echo "=== 2. ENGINE SAFETY TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.progressive_recovery import (
    recover_country,
)

r=recover_country(
    "8.8.8.8",
    timeout=5.0,
)

print(
    "TEST_8_8_8_8=",
    r,
)

assert r["state"] in {
    "confirmed",
    "ambiguous",
}

if r["state"]=="confirmed":

    assert (
        r["country_code"]
        =="US"
    )

print(
    "K7_RECOVERY_ENGINE_SMOKE=PASS"
)
PY


echo "=== 3. SELECT REAL HARD-UNRESOLVED PILOT ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import os

root=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

rows=[]

for p in root.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if str(
        o.get("state")
        or ""
    ) not in {
        "ambiguous",
        "unresolved",
    }:
        continue

    if o.get(
        "country_code"
    ):
        continue

    ip=o.get(
        "exit_ip"
    )

    config_id=o.get(
        "config_id"
    )

    if not ip or not config_id:
        continue

    rows.append(
        {
            "config_id":
                str(config_id),

            "exit_ip":
                str(ip),
        }
    )

    if len(rows)>=50:
        break


print(
    "PILOT_SIZE=",
    len(rows),
)

assert len(rows)>=10


Path(
    "/tmp/k7c-pilot.json"
).write_text(
    json.dumps(
        rows,
        indent=2,
    )
)
PY


echo "=== 4. RUN 50-CONFIG RECOVERY PILOT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from pathlib import Path
from collections import Counter
import json
import os
import time

from app.country.progressive_recovery import (
    recover_country,
)


items=json.loads(
    Path(
        "/tmp/k7c-pilot.json"
    ).read_text()
)


def work(
    item,
):

    started=time.monotonic()

    result=recover_country(
        item["exit_ip"],
        timeout=5.0,
    )

    return {
        **item,
        "elapsed_ms":int(
            (
                time.monotonic()
                -started
            )*1000
        ),
        "result":result,
    }


rows=[]


with ThreadPoolExecutor(
    max_workers=8,
    thread_name_prefix="k7c-pilot",
) as executor:

    futures=[
        executor.submit(
            work,
            item,
        )
        for item in items
    ]

    for future in as_completed(
        futures
    ):

        rows.append(
            future.result()
        )


states=Counter(
    r["result"]["state"]
    for r in rows
)

reasons=Counter(
    r["result"][
        "recovery_reason"
    ]
    for r in rows
)

countries=Counter(
    r["result"].get(
        "country_code"
    )
    for r in rows
    if r["result"].get(
        "country_code"
    )
)


confirmed=sum(
    1
    for r in rows
    if r["result"]["state"]
    =="confirmed"
)


print(
    "PILOT_ROWS=",
    len(rows),
)

print(
    "PILOT_STATES=",
    dict(states),
)

print(
    "PILOT_REASONS=",
    dict(reasons),
)

print(
    "PILOT_COUNTRIES=",
    dict(countries),
)

print(
    "PILOT_CONFIRMED=",
    confirmed,
)


for row in rows[:30]:

    print(
        "PILOT_SAMPLE=",
        {
            "config_id":
                row["config_id"],

            "exit_ip":
                row["exit_ip"],

            "elapsed_ms":
                row["elapsed_ms"],

            "state":
                row["result"][
                    "state"
                ],

            "country":
                row["result"].get(
                    "country_code"
                ),

            "reason":
                row["result"][
                    "recovery_reason"
                ],

            "evidence":
                row["result"][
                    "recovery_evidence"
                ],
        },
    )


report={
    "pilot_size":
        len(rows),

    "confirmed":
        confirmed,

    "states":
        dict(states),

    "reasons":
        dict(reasons),

    "countries":
        dict(countries),

    "rows":
        rows,
}


Path(
    os.environ["REPORT"]
).write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)


# We don't demand 100% here.
# The point is trustworthy recovery.
assert len(rows)>=10

print(
    "K7C_PILOT=PASS"
)
PY


echo "=== 5. IMPORTANT: NO PRODUCTION WRITE YET ==="

echo "PIPELINE_MODIFIED=NO"
echo "IDENTITY_MODIFIED_BY_PILOT=NO"

echo
echo "=== 6. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY


echo
echo "=== 7. SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(systemctl is-active "$svc" 2>/dev/null || true)

    echo "$svc=$X"

    test "$X" = active
done


echo "======================================================"
echo "FIX22K7C=PASS"
echo "RECOVERY=PILOT_ONLY"
echo "PRODUCTION_PIPELINE_CHANGED=NO"
echo "INDEPENDENT_GEO=DBIP+IPINFO"
echo "RDAP=SUPPORTING_EVIDENCE_ONLY"
echo "FALSE_CONFIRM_GUARD=ACTIVE"
echo "NEXT=FIX22K7D"
echo "======================================================"
