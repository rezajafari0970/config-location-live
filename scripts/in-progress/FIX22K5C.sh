#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

GP="$R/app/country/geo_providers.py"
GI="$R/app/country/geo_intelligence.py"

REPORT=/var/lib/config-location/country/k5-production-benchmark.json

echo "=== 1. VERIFY K5 CODE ==="

grep -q \
'FIX22K5_PARALLEL_GEO' \
"$GP"

grep -q \
'evidence_grace_seconds' \
"$GP"

"$PY" -m py_compile \
"$GP" \
"$GI" \
"$R/app/country/geo_consensus.py" \
"$R/app/country/pipeline.py"

echo "K5_CODE=PASS"


echo
echo "=== 2. 50 REAL UNIQUE EXIT IPS ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
from statistics import mean
import json
import os
import time

from app.country.geo_providers import (
    lookup_all,
)


H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

seen=set()
ips=[]

for p in H.glob("*.json"):

    try:
        h=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    fast=(
        (
            h.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    if not isinstance(fast,dict):
        continue

    ip=fast.get("exit_ip")

    if not ip:
        continue

    ip=str(ip)

    if ip in seen:
        continue

    seen.add(ip)
    ips.append(ip)

    if len(ips)>=50:
        break


print(
    "UNIQUE_TEST_IPS=",
    len(ips),
)

assert len(ips)>=30


samples=[]

for index,ip in enumerate(
    ips,
    1,
):

    started=time.monotonic()

    rows=lookup_all(
        ip,
        timeout=4.0,
        minimum_agreement=2,
        evidence_grace_seconds=0.35,
    )

    elapsed_ms=int(
        (
            time.monotonic()
            - started
        )
        *1000
    )


    countries=Counter()

    successful=0
    asn_rows=0
    network_rows=0

    for row in rows:

        if row.success:
            successful+=1

        if row.asn:
            asn_rows+=1

        if row.network_name:
            network_rows+=1

        if (
            row.success
            and row.country_code
        ):

            code=str(
                row.country_code
            ).strip().upper()

            if len(code)==2:
                countries[
                    code
                ]+=1


    agreed=(
        max(
            countries.values()
        )
        if countries
        else 0
    )

    consensus=(
        agreed>=2
    )


    samples.append(
        {
            "ip":ip,
            "elapsed_ms":
                elapsed_ms,

            "provider_rows":
                len(rows),

            "successful":
                successful,

            "countries":
                dict(countries),

            "agreed":
                agreed,

            "consensus":
                consensus,

            "asn_rows":
                asn_rows,

            "network_rows":
                network_rows,
        }
    )


    print(
        f"{index:02d}",
        ip,
        "ms=",
        elapsed_ms,
        "rows=",
        len(rows),
        "countries=",
        dict(countries),
        "consensus=",
        consensus,
    )


times=sorted(
    s["elapsed_ms"]
    for s in samples
)


def pct(x):

    i=min(
        len(times)-1,
        int(
            (len(times)-1)
            *x
        ),
    )

    return times[i]


consensus_count=sum(
    1
    for s in samples
    if s["consensus"]
)

any_geo=sum(
    1
    for s in samples
    if s["successful"]>=1
)

asn_any=sum(
    1
    for s in samples
    if s["asn_rows"]>=1
)

network_any=sum(
    1
    for s in samples
    if s["network_rows"]>=1
)


consensus_rate=(
    consensus_count
    /len(samples)
)


result={
    "sample_size":
        len(samples),

    "any_geo":
        any_geo,

    "consensus":
        consensus_count,

    "consensus_rate":
        consensus_rate,

    "asn_evidence":
        asn_any,

    "network_evidence":
        network_any,

    "latency_ms":{
        "min":
            times[0],

        "p50":
            pct(.50),

        "p90":
            pct(.90),

        "p95":
            pct(.95),

        "p99":
            pct(.99),

        "max":
            times[-1],

        "avg":
            round(
                mean(times),
                2,
            ),
    },

    "samples":
        samples,
}


Path(
    os.environ["REPORT"]
).write_text(
    json.dumps(
        result,
        indent=2,
        sort_keys=True,
    )
)


print()
print(
    "SAMPLE_SIZE=",
    len(samples),
)

print(
    "ANY_GEO=",
    any_geo,
)

print(
    "CONSENSUS=",
    consensus_count,
)

print(
    "CONSENSUS_RATE=",
    round(
        consensus_rate,
        4,
    ),
)

print(
    "ASN_EVIDENCE=",
    asn_any,
)

print(
    "NETWORK_EVIDENCE=",
    network_any,
)

print(
    "MIN_MS=",
    times[0],
)

print(
    "P50_MS=",
    pct(.50),
)

print(
    "P90_MS=",
    pct(.90),
)

print(
    "P95_MS=",
    pct(.95),
)

print(
    "P99_MS=",
    pct(.99),
)

print(
    "MAX_MS=",
    times[-1],
)

print(
    "AVG_MS=",
    round(
        mean(times),
        2,
    ),
)


# Accuracy / reliability:
assert (
    any_geo
    /len(samples)
) >= .95

# Do not force ambiguous Geo into a country.
assert consensus_rate >= .85

# Latency guard.
assert pct(.95) < 2000
assert times[-1] < 5000

# Evidence must still exist despite early exit.
assert asn_any>=1
assert network_any>=1


print(
    "K5_REGRESSION_GATES=PASS"
)
PY


echo
echo "=== 3. CONSENSUS SEMANTICS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_providers import (
    GeoLookup,
)

from app.country.geo_consensus import (
    geo_to_evidence,
)

from app.country.consensus import (
    decide_country_consensus,
)


# Two agreeing providers must confirm.
agree=[
    GeoLookup(
        provider="a",
        success=True,
        ip="8.8.8.8",
        country_code="US",
    ),
    GeoLookup(
        provider="b",
        success=True,
        ip="8.8.8.8",
        country_code="US",
    ),
]

r=decide_country_consensus(
    config_id="k5-agree",
    evidence=geo_to_evidence(
        agree
    ),
    minimum_agreement=2,
)

assert r.state.value=="confirmed"
assert r.country_code=="US"


# Two conflicting providers must NOT confirm.
conflict=[
    GeoLookup(
        provider="a",
        success=True,
        ip="8.8.8.8",
        country_code="GB",
    ),
    GeoLookup(
        provider="b",
        success=True,
        ip="8.8.8.8",
        country_code="FR",
    ),
]

r2=decide_country_consensus(
    config_id="k5-conflict",
    evidence=geo_to_evidence(
        conflict
    ),
    minimum_agreement=2,
)

print(
    "CONFLICT_STATE=",
    r2.state.value,
)

assert r2.state.value!="confirmed"

print(
    "NO_FALSE_CONFIRMATION=PASS"
)
PY


echo
echo "=== 4. K4 PRESERVATION ==="

grep -q \
'geo_singleflight_lock' \
"$GI"

grep -q \
'waiter_cache_hit' \
"$GI"

echo "K4_CACHE_SINGLEFLIGHT=PASS"


echo
echo "=== 5. QUEUE BEFORE CONSUMER ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE=",
    s,
)

print(
    "PENDING_BEFORE_CONSUMER=",
    s.get(
        "pending",
        0,
    ),
)
PY


echo
echo "=== 6. SERVICES ==="

for svc in \
config-location-country-worker.service \
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


echo
echo "======================================================"
echo "FIX22K5C=PASS"
echo "FIX22K5=COMPLETE"
echo "PARALLEL_GEO=PRODUCTION_VERIFIED"
echo "EARLY_COUNTRY_CONSENSUS=VERIFIED"
echo "AMBIGUITY_FALSE_CONFIRM=BLOCKED"
echo "ASN_NETWORK_EVIDENCE=PRESERVED"
echo "K4_CACHE=PRESERVED"
echo "K4_SINGLEFLIGHT=PRESERVED"
echo "REPORT=$REPORT"
echo "NEXT=K1-EVENT-CONSUMER"
echo "======================================================"
