#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
IDENT="$R/app/country/country_identity.py"

MET=/var/lib/config-location/country/event-consumer-metrics.jsonl
IDENTROOT=/var/lib/config-location/country/country-identity

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K6C-$TS"

mkdir -p "$B"

cp -a "$APP" "$B/"
[ -f "$IDENT" ] && cp -a "$IDENT" "$B/" || true

echo "BACKUP=$B"


echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo "=== 2. INSTALL PER-CONFIG COUNTRY IDENTITY STORE ==="

cat >"$IDENT" <<'PY'
from __future__ import annotations

import json
import os
import time

from pathlib import Path


ROOT=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)


def _path(
    config_id: str,
) -> Path:

    return (
        ROOT
        /f"{config_id}.json"
    )


def load_identity(
    config_id: str,
) -> dict | None:

    p=_path(
        config_id
    )

    if not p.exists():
        return None


    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return None


    if not isinstance(
        o,
        dict,
    ):
        return None


    if not o.get(
        "country_code"
    ):
        return None


    if not o.get(
        "locked"
    ):
        return None


    return o


def save_identity_once(
    *,
    config_id: str,
    geo: dict,
    exit_ip: str,
) -> dict | None:

    """
    Persist Country only after a usable Geo result.

    Once persisted, this identity is immutable during
    normal Health cycles. Ambiguous/unresolved configs
    are deliberately NOT locked and remain eligible
    for later K7 recovery.
    """

    existing=load_identity(
        config_id
    )

    if existing is not None:
        return existing


    code=geo.get(
        "country_code"
    )

    state=str(
        geo.get(
            "state"
        )
        or ""
    )


    if not code:
        return None


    # K5 consensus is the normal confirmed source.
    # Cached results may contain the same confirmed
    # result with cache_hit metadata.
    if state not in {
        "confirmed",
        "confirmed_stable",
        "confirmed_rotating_ip",
    }:
        return None


    value={
        "schema_version":1,

        "config_id":
            config_id,

        "locked":
            True,

        "country_code":
            str(
                code
            ).upper(),

        "country_name":
            geo.get(
                "country_name"
            ),

        "flag":
            geo.get(
                "flag"
            ),

        "asn":
            geo.get(
                "asn"
            ),

        "network_name":
            geo.get(
                "network_name"
            ),

        "network_type":
            geo.get(
                "network_type"
            ),

        "country_confidence":
            geo.get(
                "country_confidence"
            ),

        "first_exit_ip":
            str(
                exit_ip
            ),

        "geo_state":
            state,

        "determined_epoch":
            int(
                time.time()
            ),

        "source":
            "k6c-country-once",
    }


    ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    p=_path(
        config_id
    )

    # Atomic create semantics:
    # a competing thread/process must never overwrite
    # an already accepted Country identity.
    try:

        fd=os.open(
            p,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL,
            0o600,
        )

    except FileExistsError:

        return load_identity(
            config_id
        )


    try:

        os.write(
            fd,
            json.dumps(
                value,
                ensure_ascii=False,
                sort_keys=True,
                indent=2,
            ).encode(),
        )

        os.fsync(fd)

    finally:

        os.close(fd)


    return value


def identity_to_geo(
    identity: dict,
) -> dict:

    """
    Shape compatible with the fields consumed by the
    Event Consumer without invoking Geo providers.
    """

    return {
        "state":
            "confirmed",

        "country_code":
            identity.get(
                "country_code"
            ),

        "country_name":
            identity.get(
                "country_name"
            ),

        "flag":
            identity.get(
                "flag"
            ),

        "asn":
            identity.get(
                "asn"
            ),

        "network_name":
            identity.get(
                "network_name"
            ),

        "network_type":
            identity.get(
                "network_type"
            ),

        "country_confidence":
            identity.get(
                "country_confidence"
            ),

        "cache_hit":
            True,

        "singleflight_role":
            "config_country_identity",

        "country_identity_hit":
            True,
    }
PY


"$PY" -m py_compile "$IDENT"

echo "COUNTRY_IDENTITY_STORE=PASS"


echo "=== 3. PATCH CONSUMER SHORT-CIRCUIT ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["APP"]
)

s=p.read_text()


import_marker='''from app.country.rotating_exit_state import (
    observe as observe_rotating_exit,
)
'''

import_new='''from app.country.rotating_exit_state import (
    observe as observe_rotating_exit,
)

from app.country.country_identity import (
    identity_to_geo,
    load_identity,
    save_identity_once,
)
'''

if (
    "from app.country.country_identity import"
    not in s
):

    if import_marker not in s:
        raise SystemExit(
            "ERROR: rotating import marker missing"
        )

    s=s.replace(
        import_marker,
        import_new,
        1,
    )


old='''    # K2 boundary:
    # absolutely no second Xray or Exit-IP probe.
    geo=resolve_geo(
        config_id=config_id,
        ip=exit_ip,
    )
'''

new='''    # K6C:
    # Country detection is performed at most once
    # after successful consensus for this config.
    #
    # Future Health generations may have a new
    # Exit-IP, but Geo providers are NOT called
    # again for a config with locked Country.
    identity=load_identity(
        config_id
    )

    if identity is not None:

        geo=identity_to_geo(
            identity
        )

        geo_source=(
            "config_country_identity"
        )

    else:

        # K2 boundary:
        # absolutely no second Xray or Exit-IP probe.
        geo=resolve_geo(
            config_id=config_id,
            ip=exit_ip,
        )

        identity=save_identity_once(
            config_id=config_id,
            geo=geo,
            exit_ip=exit_ip,
        )

        geo_source=(
            "geo_first_detection"
        )
'''


if old in s:

    s=s.replace(
        old,
        new,
        1,
    )

elif "config_country_identity" not in s:

    raise SystemExit(
        "ERROR: resolve_geo block not found"
    )


meta_marker='''            "rotating_exit":
                rotating,
'''

meta_new='''            "rotating_exit":
                rotating,

            "geo_source":
                geo_source,

            "country_detection_once":
                True,
'''

if (
    meta_marker in s
    and '"country_detection_once"' not in s
):

    s=s.replace(
        meta_marker,
        meta_new,
        1,
    )


metric_marker='''            "singleflight_role":
                geo.get(
                    "singleflight_role"
                ),
'''

metric_new='''            "singleflight_role":
                geo.get(
                    "singleflight_role"
                ),

            "geo_source":
                geo_source,

            "country_identity_hit":
                (
                    geo_source
                    =="config_country_identity"
                ),
'''

if (
    metric_marker in s
    and '"country_identity_hit"' not in s
):

    s=s.replace(
        metric_marker,
        metric_new,
        1,
    )


p.write_text(s)

print(
    "COUNTRY_ONCE_SHORTCIRCUIT_PATCH=PASS"
)
PY


echo "=== 4. COMPILE ==="

"$PY" -m py_compile \
"$APP" \
"$IDENT" \
"$R/app/country/rotating_exit_state.py" \
"$R/app/country/geo_intelligence.py"

echo "COMPILE=PASS"


echo "=== 5. SYNTHETIC IDENTITY CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.country_identity import (
    _path,
    identity_to_geo,
    load_identity,
    save_identity_once,
)

cid="k6c-identity-test"

try:
    _path(cid).unlink()
except FileNotFoundError:
    pass


# Ambiguous result must NOT lock Country.
x=save_identity_once(
    config_id=cid,
    exit_ip="1.1.1.1",
    geo={
        "state":"ambiguous",
        "country_code":None,
    },
)

assert x is None
assert load_identity(cid) is None


# Confirmed result locks once.
a=save_identity_once(
    config_id=cid,
    exit_ip="1.1.1.1",
    geo={
        "state":"confirmed",
        "country_code":"DE",
        "country_name":"Germany",
        "asn":"AS1",
    },
)

assert a
assert a["country_code"]=="DE"


# Attempted later overwrite must not change Country.
b=save_identity_once(
    config_id=cid,
    exit_ip="2.2.2.2",
    geo={
        "state":"confirmed",
        "country_code":"FR",
        "country_name":"France",
    },
)

assert b["country_code"]=="DE"


g=identity_to_geo(b)

assert g["country_code"]=="DE"
assert (
    g["singleflight_role"]
    =="config_country_identity"
)

print(
    "AMBIGUOUS_NOT_LOCKED=PASS"
)

print(
    "FIRST_CONFIRMED_LOCK=PASS"
)

print(
    "LATER_GEO_OVERWRITE_BLOCKED=PASS"
)

print(
    "IDENTITY_SHORTCIRCUIT=PASS"
)


try:
    _path(cid).unlink()
except FileNotFoundError:
    pass
PY


echo "=== 6. STATIC NO-SECOND-PROBE VERIFY ==="

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

grep -q \
'load_identity' \
"$APP"

grep -q \
'save_identity_once' \
"$APP"

grep -q \
'config_country_identity' \
"$APP"

echo "COUNTRY_ONCE_CODE=PASS"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo "=== 7. RESET OBSERVATION METRICS ==="

rm -f "$MET"


echo "=== 8. START CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo "=== 9. REAL 3-MINUTE COUNTRY-ONCE OBSERVATION ==="

for i in $(seq 1 18)
do

    sleep 10

    echo "T=$((i*10))s"

    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY

done


echo "=== 10. REAL SHORT-CIRCUIT ANALYSIS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

met=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

rows=[]

if met.exists():

    for line in met.read_text().splitlines():

        try:
            rows.append(
                json.loads(line)
            )
        except Exception:
            pass


processed=[
    r
    for r in rows
    if r.get("status")=="processed"
]

sources=Counter(
    r.get(
        "geo_source",
        "unknown",
    )
    for r in processed
)


print(
    "PROCESSED=",
    len(processed),
)

print(
    "GEO_SOURCES=",
    dict(sources),
)


identity_hits=sources.get(
    "config_country_identity",
    0,
)

first_geo=sources.get(
    "geo_first_detection",
    0,
)


print(
    "IDENTITY_HITS=",
    identity_hits,
)

print(
    "FIRST_GEO_DETECTIONS=",
    first_geo,
)


identity_root=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

identity_files=list(
    identity_root.glob(
        "*.json"
    )
)

valid=0
invalid=0

for p in identity_files:

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        invalid+=1
        continue

    if (
        o.get("locked") is True
        and o.get("country_code")
    ):
        valid+=1
    else:
        invalid+=1


print(
    "IDENTITY_FILES=",
    len(identity_files),
)

print(
    "IDENTITY_VALID=",
    valid,
)

print(
    "IDENTITY_INVALID=",
    invalid,
)


assert invalid==0

# We need at least one real persisted identity.
assert valid>=1


print(
    "REAL_COUNTRY_IDENTITY_STORE=PASS"
)
PY


echo "=== 11. K6 STATE DISTRIBUTION ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/"
    "rotating-exit-history"
)

states=Counter()
reasons=Counter()

for p in root.glob(
    "*.json"
):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    v=(
        o.get(
            "last_verdict"
        )
        or {}
    )

    states[
        v.get(
            "state",
            "unknown",
        )
    ]+=1

    reasons[
        v.get(
            "reason",
            "unknown",
        )
    ]+=1


print(
    "STATES=",
    dict(states),
)

print(
    "REASONS=",
    dict(reasons),
)

print(
    "K6_STATE_AUDIT=PASS"
)
PY


echo "=== 12. GEO CACHE / SINGLEFLIGHT PRESERVED ==="

grep -q \
'geo_singleflight_lock' \
"$R/app/country/geo_intelligence.py"

grep -q \
'FIX22K5_PARALLEL_GEO' \
"$R/app/country/geo_providers.py"

echo "K4_K5=PRESERVED"


echo "=== 13. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE_FINAL=",stats())
PY


echo "=== 14. SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
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
echo "FIX22K6C=PASS"
echo "FIX22K6=COMPLETE"
echo "COUNTRY_DETECTION=ONCE_PER_CONFIRMED_CONFIG"
echo "CONFIRMED_COUNTRY=IMMUTABLE_DURING_HEALTH_CYCLES"
echo "AMBIGUOUS_UNRESOLVED=LEFT_FOR_K7_RECOVERY"
echo "ROTATING_EXIT_TEMPORAL_STATE=ACTIVE"
echo "K4_CACHE_SINGLEFLIGHT=PRESERVED"
echo "K5_PARALLEL_GEO=PRESERVED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K7"
echo "======================================================"
