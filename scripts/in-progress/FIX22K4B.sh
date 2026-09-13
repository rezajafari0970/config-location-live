#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

GC="$R/app/country/geo_cache.py"
GI="$R/app/country/geo_intelligence.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K4B-$TS"

mkdir -p "$B"

cp -a "$GC" "$B/"
cp -a "$GI" "$B/"

echo "BACKUP=$B"


echo "=== 1. ADD PER-IP SINGLE-FLIGHT LOCK ==="

export GC

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["GC"])
s=p.read_text()

if "def geo_singleflight_lock(" in s:
    print(
        "SINGLEFLIGHT_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


s=s.replace(
    "import tempfile\n",
    "import tempfile\n"
    "import fcntl\n"
    "\n"
    "from contextlib import contextmanager\n",
    1,
)


marker='''def cache_path(
    ip: str,
) -> Path:

    return (
        CACHE_ROOT
        / f"{_key(ip)}.json"
    )
'''


addition='''def cache_path(
    ip: str,
) -> Path:

    return (
        CACHE_ROOT
        / f"{_key(ip)}.json"
    )


def lock_path(
    ip: str,
) -> Path:

    return (
        CACHE_ROOT
        / "locks"
        / f"{_key(ip)}.lock"
    )


@contextmanager
def geo_singleflight_lock(
    *,
    ip: str,
):

    """
    K4 per-IP cross-process single-flight.

    Different IPs never block each other.
    Same IP has exactly one lookup owner.
    """

    p=lock_path(ip)

    p.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd=os.open(
        p,
        os.O_RDWR
        | os.O_CREAT,
        0o600,
    )

    try:

        fcntl.flock(
            fd,
            fcntl.LOCK_EX,
        )

        yield

    finally:

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_UN,
            )
        finally:
            os.close(fd)
'''


if marker not in s:
    raise SystemExit(
        "ERROR: cache_path contract not found"
    )

s=s.replace(
    marker,
    addition,
    1,
)

p.write_text(s)

print(
    "SINGLEFLIGHT_LOCK=PASS"
)
PY


echo "=== 2. WRAP RESOLVE_GEO MISS PATH ==="

export GI

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["GI"])
s=p.read_text()

if "FIX22K4_SINGLEFLIGHT_OWNER" in s:
    print(
        "RESOLVE_SINGLEFLIGHT_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


# Extend existing geo_cache import.
old='''from .geo_cache import (
    load_geo_cache,
    save_geo_cache,
)
'''

new='''from .geo_cache import (
    geo_singleflight_lock,
    load_geo_cache,
    save_geo_cache,
)
'''

if old not in s:
    raise SystemExit(
        "ERROR: geo_cache import contract "
        "not found"
    )

s=s.replace(
    old,
    new,
    1,
)


# Rather than reimplementing the body, split current
# resolve_geo into a cached public wrapper + original
# uncached owner implementation.

tree=ast.parse(s)

fn=None

for n in tree.body:

    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="resolve_geo"
    ):
        fn=n
        break

assert fn is not None


lines=s.splitlines(
    keepends=True
)

original="".join(
    lines[
        fn.lineno-1:
        fn.end_lineno
    ]
)


# Rename original function and remove its first cache
# lookup block. The owner is called only after the
# double-check under lock.

owner=original.replace(
    "def resolve_geo(",
    "def _resolve_geo_uncached(",
    1,
)


start=owner.find(
'''    cached=load_geo_cache(
''')

lookup=owner.find(
'''    rows=lookup_all(
''')

if start < 0 or lookup < 0:
    raise SystemExit(
        "ERROR: cache/lookup boundary not found"
    )

owner=(
    owner[:start]
    +'''    # FIX22K4_SINGLEFLIGHT_OWNER
'''
    +owner[lookup:]
)


wrapper='''def resolve_geo(
    *,
    config_id: str,
    ip: str,
    cache_ttl_seconds: int = 604800,
) -> dict:

    # Fast lock-free cache hit.
    cached=load_geo_cache(
        ip=ip,
        ttl_seconds=cache_ttl_seconds,
    )

    if cached is not None:

        return {
            **cached,
            "cache_hit":True,
            "singleflight_role":
                "cache_hit",
        }


    # Cache miss: serialize only this IP.
    with geo_singleflight_lock(
        ip=ip,
    ):

        # Critical double-check.
        # Another process may have populated
        # the cache while we waited.
        cached=load_geo_cache(
            ip=ip,
            ttl_seconds=cache_ttl_seconds,
        )

        if cached is not None:

            return {
                **cached,
                "cache_hit":True,
                "singleflight_role":
                    "waiter_cache_hit",
            }


        result=_resolve_geo_uncached(
            config_id=config_id,
            ip=ip,
            cache_ttl_seconds=
                cache_ttl_seconds,
        )

        return {
            **result,
            "singleflight_role":
                "owner",
        }


'''


replacement=(
    wrapper
    + owner
)


lines[
    fn.lineno-1:
    fn.end_lineno
]=[
    x+"\n"
    for x in replacement.splitlines()
]


new_s="".join(lines)

ast.parse(new_s)

p.write_text(new_s)

print(
    "RESOLVE_SINGLEFLIGHT=PASS"
)
PY


echo "=== 3. COMPILE ==="

"$PY" -m py_compile \
"$GC" \
"$GI" \
"$R/app/country/pipeline.py"

echo "COMPILE=PASS"


echo "=== 4. VERIFY STRUCTURE ==="

grep -n \
-B8 -A100 \
'def resolve_geo' \
"$GI" \
| head -n 150

grep -n \
-B5 -A55 \
'def geo_singleflight_lock' \
"$GC"


echo "=== 5. SYNTHETIC CROSS-PROCESS SINGLE-FLIGHT TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import multiprocessing as mp
import os
import time

from pathlib import Path

import app.country.geo_intelligence as gi
import app.country.geo_cache as gc


IP="203.0.113.77"

# Dedicated test key only.
cp=gc.cache_path(IP)

try:
    cp.unlink()
except FileNotFoundError:
    pass


counter=Path(
    "/tmp/k4-singleflight-counter"
)

counter.write_text("")


def worker(q):

    # Patch only inside child process.
    def fake_lookup_all(
        ip,
        timeout=8.0,
    ):

        with counter.open("a") as f:
            f.write(
                f"{os.getpid()}\\n"
            )
            f.flush()
            os.fsync(
                f.fileno()
            )

        time.sleep(1.0)

        # Use real GeoLookup contract.
        GP=__import__(
            "app.country.geo_providers",
            fromlist=["GeoLookup"],
        )

        return [
            GP.GeoLookup(
                provider="fake1",
                ip=ip,
                success=True,
                country_code="US",
                country_name="United States",
                asn="AS1",
                network_name="Test Network",
                duration_ms=10,
                error=None,
            ),
            GP.GeoLookup(
                provider="fake2",
                ip=ip,
                success=True,
                country_code="US",
                country_name="United States",
                asn="AS1",
                network_name="Test Network",
                duration_ms=10,
                error=None,
            ),
        ]


    gi.lookup_all=fake_lookup_all

    r=gi.resolve_geo(
        config_id=(
            "k4-test-"
            +str(os.getpid())
        ),
        ip=IP,
    )

    q.put(
        {
            "role":
                r.get(
                    "singleflight_role"
                ),

            "country":
                r.get(
                    "country_code"
                ),

            "cache_hit":
                r.get(
                    "cache_hit"
                ),
        }
    )


ctx=mp.get_context("fork")
q=ctx.Queue()

procs=[
    ctx.Process(
        target=worker,
        args=(q,),
    )
    for _ in range(8)
]


started=time.monotonic()

for p in procs:
    p.start()

results=[]

for _ in procs:
    results.append(
        q.get(
            timeout=15
        )
    )

for p in procs:
    p.join(
        timeout=15
    )

elapsed=time.monotonic()-started


calls=[
    x
    for x in counter.read_text().splitlines()
    if x.strip()
]


print(
    "LOOKUP_CALLS=",
    len(calls),
)

print(
    "RESULTS=",
    results,
)

print(
    "ELAPSED=",
    round(
        elapsed,
        3,
    ),
)


assert len(calls)==1

assert all(
    r["country"]=="US"
    for r in results
)

roles=[
    r["role"]
    for r in results
]

assert roles.count(
    "owner"
)==1

assert roles.count(
    "waiter_cache_hit"
)==7


print(
    "CROSS_PROCESS_SINGLEFLIGHT=PASS"
)


# Remove synthetic cache entry.
try:
    cp.unlink()
except FileNotFoundError:
    pass
PY


echo "=== 6. DIFFERENT-IP PARALLELISM TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import multiprocessing as mp
import time

from app.country.geo_cache import (
    geo_singleflight_lock,
)


def worker(
    ip,
    q,
):

    started=time.monotonic()

    with geo_singleflight_lock(
        ip=ip,
    ):
        time.sleep(1.0)

    q.put(
        time.monotonic()
        - started
    )


ctx=mp.get_context("fork")
q=ctx.Queue()

a=ctx.Process(
    target=worker,
    args=(
        "203.0.113.101",
        q,
    ),
)

b=ctx.Process(
    target=worker,
    args=(
        "203.0.113.102",
        q,
    ),
)

started=time.monotonic()

a.start()
b.start()

x=q.get(timeout=5)
y=q.get(timeout=5)

a.join()
b.join()

elapsed=time.monotonic()-started

print(
    "TOTAL_ELAPSED=",
    round(
        elapsed,
        3,
    ),
)

print(
    "INDIVIDUAL=",
    round(x,3),
    round(y,3),
)

# If a global lock were used this would
# be approximately 2 seconds.
assert elapsed < 1.8

print(
    "PER_IP_PARALLELISM=PASS"
)
PY


echo "=== 7. REAL CACHE SMOKE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.geo_intelligence import (
    resolve_geo,
)

root=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

ip=None

for p in root.glob("*.json"):

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

    candidate=fast.get(
        "exit_ip"
    )

    if candidate:
        ip=str(candidate)
        break


assert ip

print(
    "TEST_IP=",
    ip,
)


a=resolve_geo(
    config_id="k4-real-a",
    ip=ip,
)

b=resolve_geo(
    config_id="k4-real-b",
    ip=ip,
)


print(
    "FIRST_ROLE=",
    a.get(
        "singleflight_role"
    ),
)

print(
    "SECOND_ROLE=",
    b.get(
        "singleflight_role"
    ),
)

print(
    "FIRST_COUNTRY=",
    a.get(
        "country_code"
    ),
)

print(
    "SECOND_COUNTRY=",
    b.get(
        "country_code"
    ),
)


assert (
    a.get("country_code")
    ==
    b.get("country_code")
)

if (
    a.get("state")
    =="confirmed"
):

    assert (
        b.get(
            "cache_hit"
        )
        is True
    )


print(
    "REAL_CACHE_SMOKE=PASS"
)
PY


echo "=== 8. SERVICES ==="

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
echo "FIX22K4B=PASS"
echo "GEO_CACHE=EXISTING_REUSED"
echo "CACHE_TTL=7D"
echo "SINGLEFLIGHT=CROSS_PROCESS"
echo "LOCK_SCOPE=PER_IP"
echo "DOUBLE_CHECK_AFTER_LOCK=YES"
echo "ATOMIC_CACHE_WRITE=PRESERVED"
echo "DIFFERENT_IPS_PARALLEL=YES"
echo "NEXT=FIX22K4C"
echo "======================================================"
