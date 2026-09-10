#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

GP="$R/app/country/geo_providers.py"
GI="$R/app/country/geo_intelligence.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K5B-$TS"

mkdir -p "$B"

cp -a "$GP" "$B/"
cp -a "$GI" "$B/"

echo "BACKUP=$B"


echo "=== 1. INSTALL PARALLEL GEO LOOKUP ==="

export GP

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["GP"])
s=p.read_text()

if "FIX22K5_PARALLEL_GEO" in s:
    print("K5_PARALLEL_ALREADY_PRESENT=YES")
    raise SystemExit(0)


# Imports
s=s.replace(
    "import time\n",
    "import time\n"
    "\n"
    "from collections import Counter\n"
    "from concurrent.futures import (\n"
    "    ThreadPoolExecutor,\n"
    "    as_completed,\n"
    "    TimeoutError as FuturesTimeoutError,\n"
    ")\n",
    1,
)


tree=ast.parse(s)

target=None

for n in tree.body:
    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="lookup_all"
    ):
        target=n
        break

assert target is not None


new_func=r'''def lookup_all(
    ip: str,
    timeout: float = 8.0,
    minimum_agreement: int = 2,
    evidence_grace_seconds: float = 0.35,
) -> list[GeoLookup]:
    """
    FIX22K5_PARALLEL_GEO

    All independent Geo providers start concurrently.

    Once country consensus is reached, allow a short
    evidence grace window for ASN/network enrichment.
    Do not hold the caller for a slow third provider.
    """

    providers=tuple(
        DEFAULT_PROVIDERS
    )

    if not providers:
        return []


    executor=ThreadPoolExecutor(
        max_workers=len(providers),
        thread_name_prefix="country-geo",
    )


    futures={
        executor.submit(
            provider,
            ip,
            timeout,
        ):provider
        for provider in providers
    }


    rows=[]
    countries=Counter()

    consensus_reached=False
    consensus_at=None


    def _country_key(
        row: GeoLookup,
    ) -> str | None:

        if not row.success:
            return None

        code=row.country_code

        if not isinstance(code,str):
            return None

        code=code.strip().upper()

        if len(code)!=2:
            return None

        return code


    try:

        pending=set(
            futures.keys()
        )

        while pending:

            # Before consensus, provider timeout is
            # the effective upper bound.
            wait_timeout=(
                timeout + 2.5
            )

            # After consensus, only wait for the
            # bounded evidence grace window.
            if (
                consensus_reached
                and consensus_at
                is not None
            ):
                elapsed=(
                    time.monotonic()
                    - consensus_at
                )

                remaining=(
                    evidence_grace_seconds
                    - elapsed
                )

                if remaining <= 0:
                    break

                wait_timeout=remaining


            try:

                future=next(
                    as_completed(
                        pending,
                        timeout=wait_timeout,
                    )
                )

            except FuturesTimeoutError:
                break


            pending.discard(
                future
            )


            provider=futures[
                future
            ]


            try:
                row=future.result()

            except Exception as exc:

                row=GeoLookup(
                    provider=getattr(
                        provider,
                        "__name__",
                        "unknown",
                    ),
                    success=False,
                    ip=ip,
                    error=(
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    )[:500],
                )


            rows.append(
                row
            )


            key=_country_key(
                row
            )

            if key is not None:

                countries[
                    key
                ]+=1


                if (
                    not consensus_reached
                    and countries[key]
                    >= minimum_agreement
                ):

                    consensus_reached=True
                    consensus_at=(
                        time.monotonic()
                    )


                    # If all providers already
                    # completed, no grace is needed.
                    if not pending:
                        break


        # Collect futures that completed during the
        # grace boundary but were not consumed yet.
        for future in list(
            pending
        ):

            if not future.done():
                continue

            pending.discard(
                future
            )

            provider=futures[
                future
            ]

            try:
                row=future.result()
            except Exception as exc:
                row=GeoLookup(
                    provider=getattr(
                        provider,
                        "__name__",
                        "unknown",
                    ),
                    success=False,
                    ip=ip,
                    error=(
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    )[:500],
                )

            rows.append(row)


        # Cancel futures that have not started.
        # Running curl subprocesses remain bounded by
        # their own provider timeout.
        for future in pending:
            future.cancel()


        return rows


    finally:

        executor.shutdown(
            wait=False,
            cancel_futures=True,
        )
'''


lines=s.splitlines(
    keepends=True
)

replacement=[
    line+"\n"
    for line in new_func.splitlines()
]

lines[
    target.lineno-1:
    target.end_lineno
]=replacement

new="".join(lines)

ast.parse(new)

p.write_text(new)

print(
    "PARALLEL_GEO_PATCH=PASS"
)
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile \
"$GP" \
"$GI" \
"$R/app/country/geo_consensus.py" \
"$R/app/country/pipeline.py"

echo "COMPILE=PASS"


echo "=== 3. SYNTHETIC EARLY CONSENSUS TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import time

import app.country.geo_providers as m


original=m.DEFAULT_PROVIDERS


def make_provider(
    name,
    delay,
    country,
    asn,
):

    def provider(
        ip,
        timeout,
    ):

        time.sleep(delay)

        return m.GeoLookup(
            provider=name,
            success=True,
            ip=ip,
            country_code=country,
            country_name=(
                "United States"
                if country=="US"
                else "Germany"
            ),
            asn=asn,
            network_name=(
                "Synthetic Network "
                + name
            ),
            duration_ms=int(
                delay*1000
            ),
        )

    provider.__name__=name

    return provider


m.DEFAULT_PROVIDERS=(
    make_provider(
        "fast_a",
        0.20,
        "US",
        "AS1",
    ),
    make_provider(
        "fast_b",
        0.25,
        "US",
        "AS1",
    ),
    make_provider(
        "slow_c",
        2.50,
        "US",
        "AS1",
    ),
)


started=time.monotonic()

try:

    rows=m.lookup_all(
        "8.8.8.8",
        timeout=4.0,
        minimum_agreement=2,
        evidence_grace_seconds=0.35,
    )

finally:
    m.DEFAULT_PROVIDERS=original


elapsed=(
    time.monotonic()
    - started
)


print(
    "SYNTH_ROWS=",
    len(rows),
)

print(
    "SYNTH_PROVIDERS=",
    [
        r.provider
        for r in rows
    ],
)

print(
    "SYNTH_ELAPSED=",
    round(
        elapsed,
        3,
    ),
)


assert len(rows)>=2

assert sum(
    1
    for r in rows
    if r.country_code=="US"
)>=2

# Must not wait for 2.5 sec slow provider.
assert elapsed < 1.2

print(
    "EARLY_COUNTRY_CONSENSUS=PASS"
)
PY


echo "=== 4. EVIDENCE GRACE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import time

import app.country.geo_providers as m


original=m.DEFAULT_PROVIDERS


def make_provider(
    name,
    delay,
):

    def provider(
        ip,
        timeout,
    ):

        time.sleep(delay)

        return m.GeoLookup(
            provider=name,
            success=True,
            ip=ip,
            country_code="DE",
            country_name="Germany",
            asn="AS680",
            network_name="Synthetic DE",
            duration_ms=int(
                delay*1000
            ),
        )

    provider.__name__=name
    return provider


m.DEFAULT_PROVIDERS=(
    make_provider(
        "a",
        0.10,
    ),
    make_provider(
        "b",
        0.15,
    ),
    make_provider(
        "c",
        0.30,
    ),
)


try:

    rows=m.lookup_all(
        "1.1.1.1",
        timeout=2.0,
        minimum_agreement=2,
        evidence_grace_seconds=0.35,
    )

finally:
    m.DEFAULT_PROVIDERS=original


print(
    "GRACE_ROWS=",
    len(rows),
)

print(
    "GRACE_PROVIDERS=",
    [
        r.provider
        for r in rows
    ],
)


# Third provider should fit inside the grace
# window and enrich ASN/network evidence.
assert len(rows)==3

print(
    "BOUNDED_EVIDENCE_COLLECTION=PASS"
)
PY


echo "=== 5. REAL 20-IP PARALLEL BENCHMARK ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from statistics import mean
import json
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

    if not isinstance(
        fast,
        dict,
    ):
        continue

    ip=fast.get(
        "exit_ip"
    )

    if not ip:
        continue

    ip=str(ip)

    if ip in seen:
        continue

    seen.add(ip)
    ips.append(ip)

    if len(ips)>=20:
        break


assert len(ips)>=10


elapsed_rows=[]
provider_sum_rows=[]
success_rows=0
consensus_rows=0


for ip in ips:

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

    elapsed_rows.append(
        elapsed_ms
    )


    provider_sum=sum(
        max(
            0,
            int(
                r.duration_ms
                or 0
            ),
        )
        for r in rows
    )

    provider_sum_rows.append(
        provider_sum
    )


    good=[
        r
        for r in rows
        if (
            r.success
            and r.country_code
        )
    ]

    if good:
        success_rows+=1


    countries={}

    for r in good:

        code=str(
            r.country_code
        ).upper()

        countries[
            code
        ]=(
            countries.get(
                code,
                0,
            )
            +1
        )


    if (
        countries
        and max(
            countries.values()
        )>=2
    ):
        consensus_rows+=1


    print(
        "SAMPLE=",
        {
            "ip":ip,
            "elapsed_ms":
                elapsed_ms,
            "provider_rows":
                len(rows),
            "provider_sum_ms":
                provider_sum,
            "countries":
                countries,
        },
    )


times=sorted(
    elapsed_rows
)


def pct(v):

    i=min(
        len(times)-1,
        int(
            (len(times)-1)
            *v
        ),
    )

    return times[i]


print(
    "REAL_SAMPLES=",
    len(times),
)

print(
    "REAL_SUCCESS=",
    success_rows,
)

print(
    "REAL_CONSENSUS=",
    consensus_rows,
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

print(
    "AVG_PROVIDER_SUM_MS=",
    round(
        mean(
            provider_sum_rows
        ),
        2,
    ),
)


assert success_rows>=1
assert consensus_rows>=1

# Hard safety ceiling for the new bounded path.
assert pct(.95) < 6000

print(
    "REAL_PARALLEL_GEO=PASS"
)
PY


echo "=== 6. CONSENSUS COMPATIBILITY ==="

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


rows=[
    GeoLookup(
        provider="a",
        success=True,
        ip="8.8.8.8",
        country_code="US",
        country_name="United States",
        asn="AS15169",
        network_name="Google",
    ),
    GeoLookup(
        provider="b",
        success=True,
        ip="8.8.8.8",
        country_code="US",
        country_name="United States",
        asn="AS15169",
        network_name="Google",
    ),
]


e=geo_to_evidence(
    rows
)

r=decide_country_consensus(
    config_id="k5-contract",
    evidence=e,
    minimum_agreement=2,
)


print(
    "CONSENSUS_STATE=",
    r.state.value,
)

print(
    "CONSENSUS_COUNTRY=",
    r.country_code,
)

print(
    "CONSENSUS_AGREED=",
    r.providers_agreed,
)


assert r.state.value=="confirmed"
assert r.country_code=="US"
assert r.providers_agreed>=2

print(
    "CONSENSUS_COMPATIBILITY=PASS"
)
PY


echo "=== 7. K4 CACHE / SINGLEFLIGHT PRESERVED ==="

grep -q \
'geo_singleflight_lock' \
"$GI"

grep -q \
'waiter_cache_hit' \
"$GI"

echo "K4_PRESERVED=PASS"


echo "=== 8. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY


echo "=== 9. SERVICES ==="

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


echo "======================================================"
echo "FIX22K5B=PASS"
echo "PARALLEL_GEO_PROVIDERS=YES"
echo "COUNTRY_EARLY_CONSENSUS=YES"
echo "MINIMUM_AGREEMENT=2"
echo "EVIDENCE_GRACE_MS=350"
echo "ASN_NETWORK_EVIDENCE=BOUNDED_COLLECTION"
echo "K4_CACHE=PRESERVED"
echo "K4_SINGLEFLIGHT=PRESERVED"
echo "NEXT=FIX22K5C"
echo "======================================================"
