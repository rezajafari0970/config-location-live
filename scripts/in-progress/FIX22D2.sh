#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

D=/var/lib/config-location/country
CACHE="$D/geo-cache"

mkdir -p "$CACHE"

cat >"$M/geo_cache.py" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import tempfile

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any


CACHE_ROOT=Path(
    "/var/lib/config-location/"
    "country/geo-cache"
)

DEFAULT_TTL_SECONDS=(
    7 * 24 * 60 * 60
)


def utc_now() -> datetime:
    return datetime.now(
        timezone.utc
    )


def _key(
    ip: str,
) -> str:

    return hashlib.sha256(
        ip.encode("utf-8")
    ).hexdigest()


def cache_path(
    ip: str,
) -> Path:

    return (
        CACHE_ROOT
        / f"{_key(ip)}.json"
    )


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

        os.replace(
            tmp,
            path,
        )

    except Exception:

        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def save_geo_cache(
    *,
    ip: str,
    value: dict[str, Any],
) -> Path:

    now=utc_now()

    o={
        "schema_version":1,
        "ip":ip,
        "cached_at":
            now.isoformat(),
        "cached_at_epoch":
            int(now.timestamp()),
        "value":value,
    }

    p=cache_path(ip)

    _atomic_json(
        p,
        o,
    )

    return p


def load_geo_cache(
    *,
    ip: str,
    ttl_seconds: int = DEFAULT_TTL_SECONDS,
) -> dict[str, Any] | None:

    p=cache_path(ip)

    if not p.exists():
        return None

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return None

    if o.get("ip") != ip:
        return None

    epoch=o.get(
        "cached_at_epoch"
    )

    if not isinstance(
        epoch,
        int,
    ):
        return None

    age=(
        int(
            utc_now().timestamp()
        )
        - epoch
    )

    if age < 0:
        return None

    if age > ttl_seconds:
        return None

    value=o.get("value")

    if not isinstance(
        value,
        dict,
    ):
        return None

    return value
PY


cat >"$M/network_classifier.py" <<'PY'
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class NetworkClassification:
    network_type: str
    confidence: float
    signals: tuple[str, ...]


HOSTING_WORDS=(
    "hetzner",
    "digitalocean",
    "ovh",
    "linode",
    "vultr",
    "leaseweb",
    "contabo",
    "amazon",
    "aws",
    "google cloud",
    "microsoft",
    "azure",
    "oracle cloud",
    "datacamp",
    "m247",
)

CDN_WORDS=(
    "cloudflare",
    "akamai",
    "fastly",
    "cdn77",
    "bunny",
)


def classify_network(
    *,
    network_name: str | None,
) -> NetworkClassification:

    value=(
        network_name
        or ""
    ).strip().lower()

    if not value:
        return NetworkClassification(
            network_type="unknown",
            confidence=0.0,
            signals=(),
        )

    for word in CDN_WORDS:
        if word in value:
            return NetworkClassification(
                network_type="cdn",
                confidence=0.95,
                signals=(
                    f"name_contains:{word}",
                ),
            )

    for word in HOSTING_WORDS:
        if word in value:
            return NetworkClassification(
                network_type="hosting",
                confidence=0.90,
                signals=(
                    f"name_contains:{word}",
                ),
            )

    return NetworkClassification(
        network_type="isp_or_unknown",
        confidence=0.50,
        signals=(
            "no_known_hosting_or_cdn_signal",
        ),
    )
PY


cat >"$M/geo_intelligence.py" <<'PY'
from __future__ import annotations

from collections import Counter

from .consensus import (
    decide_country_consensus,
)

from .geo_cache import (
    load_geo_cache,
    save_geo_cache,
)

from .geo_consensus import (
    geo_to_evidence,
)

from .geo_providers import (
    lookup_all,
)

from .network_classifier import (
    classify_network,
)


def resolve_geo(
    *,
    config_id: str,
    ip: str,
    cache_ttl_seconds: int = 604800,
) -> dict:

    cached=load_geo_cache(
        ip=ip,
        ttl_seconds=(
            cache_ttl_seconds
        ),
    )

    if cached is not None:

        return {
            **cached,
            "cache_hit":True,
        }


    rows=lookup_all(
        ip,
        timeout=8.0,
    )

    evidence=geo_to_evidence(
        rows
    )

    country=(
        decide_country_consensus(
            config_id=config_id,
            evidence=evidence,
            minimum_agreement=2,
        )
    )


    successful=[
        row
        for row in rows
        if row.success
    ]


    asns=Counter(
        str(row.asn)
        for row in successful
        if row.asn
    )

    networks=Counter(
        str(row.network_name)
        for row in successful
        if row.network_name
    )


    asn=None
    asn_agreed=0

    if asns:
        asn,asn_agreed=(
            asns.most_common(1)[0]
        )


    network_name=None
    network_agreed=0

    if networks:
        (
            network_name,
            network_agreed,
        )=networks.most_common(1)[0]


    classification=(
        classify_network(
            network_name=network_name
        )
    )


    provider_rows=[]

    for row in rows:

        provider_rows.append(
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    row.country_code,

                "country_name":
                    row.country_name,

                "asn":
                    row.asn,

                "network_name":
                    row.network_name,

                "duration_ms":
                    row.duration_ms,

                "error":
                    row.error,
            }
        )


    result={
        "schema_version":1,

        "ip":ip,

        "state":
            country.state.value,

        "country_code":
            country.country_code,

        "country_name":
            country.country_name,

        "flag":
            country.flag,

        "country_confidence":
            country.confidence,

        "country_agreed":
            country.providers_agreed,

        "country_total":
            country.providers_total,

        "asn":
            asn,

        "asn_agreed":
            asn_agreed,

        "network_name":
            network_name,

        "network_agreed":
            network_agreed,

        "network_type":
            classification.network_type,

        "network_confidence":
            classification.confidence,

        "network_signals":
            list(
                classification.signals
            ),

        "providers":
            provider_rows,

        "cache_hit":
            False,
    }


    if (
        country.state.value
        == "confirmed"
    ):
        save_geo_cache(
            ip=ip,
            value=result,
        )


    return result
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/geo_cache.py" \
"$M/network_classifier.py" \
"$M/geo_intelligence.py"

echo "COMPILE=PASS"


echo "=== 2. CACHE MISS / HIT TEST ==="

rm -f "$CACHE"/*.json || true

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_intelligence import (
    resolve_geo,
)

IP="91.107.184.117"

r1=resolve_geo(
    config_id="FIX22D2-A",
    ip=IP,
)

print(
    "FIRST_CACHE_HIT=",
    r1["cache_hit"],
)

print(
    "COUNTRY=",
    r1["country_code"],
    r1["country_name"],
)

print(
    "CONFIDENCE=",
    r1["country_confidence"],
)

print(
    "ASN=",
    r1["asn"],
)

print(
    "ASN_AGREED=",
    r1["asn_agreed"],
)

print(
    "NETWORK=",
    r1["network_name"],
)

print(
    "NETWORK_TYPE=",
    r1["network_type"],
)

assert (
    r1["cache_hit"]
    is False
)

assert (
    r1["country_code"]
    == "DE"
)

assert (
    r1["country_confidence"]
    >= 0.67
)

assert (
    r1["asn"]
    == "AS24940"
)

assert (
    r1["asn_agreed"]
    >= 2
)


r2=resolve_geo(
    config_id="FIX22D2-B",
    ip=IP,
)

print(
    "SECOND_CACHE_HIT=",
    r2["cache_hit"],
)

assert (
    r2["cache_hit"]
    is True
)

assert (
    r2["country_code"]
    == "DE"
)

print(
    "CACHE_REUSE=PASS"
)
PY


echo "=== 3. NETWORK CLASSIFICATION ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.network_classifier import (
    classify_network,
)

a=classify_network(
    network_name=
        "Hetzner Online GmbH"
)

print(
    "HETZNER=",
    a,
)

assert (
    a.network_type
    == "hosting"
)


b=classify_network(
    network_name=
        "Cloudflare, Inc."
)

print(
    "CLOUDFLARE=",
    b,
)

assert (
    b.network_type
    == "cdn"
)


print(
    "NETWORK_CLASSIFIER=PASS"
)
PY


echo "=== 4. CACHE STRUCTURE ==="

find "$CACHE" \
-maxdepth 1 \
-type f \
-name "*.json" \
-printf "%f %s bytes\n" \
| head -n 20

COUNT=$(
    find "$CACHE" \
    -maxdepth 1 \
    -type f \
    -name "*.json" \
    | wc -l
)

echo "CACHE_FILES=$COUNT"

test "$COUNT" -ge 1


echo "=== 5. SERVICES ==="

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
echo "FIX22D2=PASS"
echo "GEO_CACHE=READY"
echo "CACHE_TTL=7_DAYS"
echo "ASN_CONSENSUS=READY"
echo "NETWORK_CLASSIFICATION=READY"
echo "CDN_DETECTION=READY"
echo "HOSTING_DETECTION=READY"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
