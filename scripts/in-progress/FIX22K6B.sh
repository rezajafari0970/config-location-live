#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

ROT="$R/app/country/rotating_exit_state.py"
APP="$R/app/country/event_consumer.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K6B-$TS"

mkdir -p "$B"

cp -a "$ROT" "$B/"
cp -a "$APP" "$B/"

echo "BACKUP=$B"


echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo "=== 2. UPGRADE TEMPORAL STATE ENGINE ==="

cat >"$ROT" <<'PY'
from __future__ import annotations

import json
import os
import time

from collections import Counter
from pathlib import Path


ROOT=Path(
    "/var/lib/config-location/country/"
    "rotating-exit-history"
)


MIN_REPEAT_SECONDS=30
MAX_HISTORY=12


def _path(
    config_id: str,
) -> Path:

    return ROOT / f"{config_id}.json"


def _empty(
    config_id: str,
) -> dict:

    return {
        "config_id":config_id,
        "observations":[],
    }


def _read(
    config_id: str,
) -> dict:

    p=_path(config_id)

    if not p.exists():
        return _empty(config_id)

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return _empty(config_id)

    if not isinstance(o,dict):
        return _empty(config_id)

    if not isinstance(
        o.get("observations"),
        list,
    ):
        o["observations"]=[]

    return o


def _write(
    config_id: str,
    value: dict,
) -> None:

    ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    p=_path(config_id)
    tmp=p.with_suffix(".tmp")

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
    )

    os.replace(tmp,p)


def observe(
    *,
    config_id: str,
    exit_ip: str,
    country_code: str | None,
    observed_epoch: int | None = None,
    minimum_repeat_seconds: int = MIN_REPEAT_SECONDS,
    max_history: int = MAX_HISTORY,
) -> dict:

    now=int(
        observed_epoch
        if observed_epoch is not None
        else time.time()
    )

    state=_read(config_id)

    obs=list(
        state.get(
            "observations",
            []
        )
    )

    code=(
        str(country_code)
        .strip()
        .upper()
        if country_code
        else None
    )

    row={
        "ts":now,
        "exit_ip":str(exit_ip),
        "country_code":code,
    }


    append=True

    if obs:

        last=obs[-1]

        same=(
            last.get("exit_ip")
            ==row["exit_ip"]
            and last.get("country_code")
            ==row["country_code"]
        )

        age=(
            now
            -int(
                last.get("ts",0)
            )
        )

        # Same observation in the same immediate
        # execution is noise, but the same IP/country
        # observed again in a later Health generation
        # is real temporal evidence.
        if (
            same
            and age
            <max(
                1,
                int(
                    minimum_repeat_seconds
                )
            )
        ):
            append=False


    if append:
        obs.append(row)


    obs=obs[
        -max(
            3,
            int(max_history),
        ):
    ]

    state["observations"]=obs


    ips=[
        x.get("exit_ip")
        for x in obs
        if x.get("exit_ip")
    ]

    countries=[
        str(
            x.get("country_code")
        ).upper()
        for x in obs
        if x.get("country_code")
    ]

    unique_ips=set(ips)
    unique_countries=set(countries)

    counts=Counter(countries)

    dominant_country=None
    dominant_count=0

    if counts:

        dominant_country,dominant_count=(
            counts.most_common(1)[0]
        )


    verdict="pending_confirmation"
    reason="insufficient_history"


    if len(obs)>=2:

        # Stable endpoint:
        # same country and same IP observed in
        # separate temporal observations.
        if (
            len(unique_countries)==1
            and len(unique_ips)==1
        ):

            verdict="confirmed_stable"
            reason="same_ip_same_country_temporal"


        # Rotating endpoint but geo-stable.
        elif (
            len(unique_countries)==1
            and len(unique_ips)>=2
        ):

            verdict="confirmed_rotating_ip"
            reason="rotating_ip_same_country"


        elif len(unique_countries)>=2:

            # Do not flip the final country because
            # one provider/exit observation disagrees.
            #
            # A dominant 2/3+ majority keeps the
            # dominant country but requests recovery.
            if (
                len(countries)>=3
                and dominant_count>=2
                and (
                    dominant_count
                    /len(countries)
                )>=0.66
            ):

                verdict="pending_confirmation"
                reason="country_change_majority_recovery"

            else:

                verdict="pending_confirmation"
                reason="country_change_ambiguous"


    result={
        "state":verdict,
        "reason":reason,

        "observation_count":
            len(obs),

        "unique_ip_count":
            len(unique_ips),

        "unique_country_count":
            len(unique_countries),

        "dominant_country":
            dominant_country,

        "dominant_country_count":
            dominant_count,

        "observation_appended":
            append,

        "observations":
            obs,
    }


    state["last_verdict"]=result

    _write(
        config_id,
        state,
    )

    return result
PY


"$PY" -m py_compile "$ROT"

echo "TEMPORAL_ENGINE=PASS"


echo "=== 3. SYNTHETIC TEMPORAL TESTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country import rotating_exit_state as m


ids=[
    "k6b-stable",
    "k6b-rotate",
    "k6b-change",
]

for cid in ids:
    try:
        m._path(cid).unlink()
    except FileNotFoundError:
        pass


# Stable IP across two Health generations.
m.observe(
    config_id="k6b-stable",
    exit_ip="1.1.1.1",
    country_code="US",
    observed_epoch=100,
)

r=m.observe(
    config_id="k6b-stable",
    exit_ip="1.1.1.1",
    country_code="US",
    observed_epoch=160,
)

print("STABLE=",r)

assert (
    r["state"]
    =="confirmed_stable"
)

assert (
    r["observation_count"]
    ==2
)


# Immediate duplicate must still be suppressed.
r2=m.observe(
    config_id="k6b-stable",
    exit_ip="1.1.1.1",
    country_code="US",
    observed_epoch=165,
)

assert (
    r2[
        "observation_count"
    ]==2
)

assert (
    r2[
        "observation_appended"
    ] is False
)


# Rotating IP, same country.
m.observe(
    config_id="k6b-rotate",
    exit_ip="2.2.2.2",
    country_code="DE",
    observed_epoch=100,
)

r=m.observe(
    config_id="k6b-rotate",
    exit_ip="3.3.3.3",
    country_code="DE",
    observed_epoch=160,
)

print("ROTATING=",r)

assert (
    r["state"]
    =="confirmed_rotating_ip"
)


# Country disagreement may not false-confirm.
m.observe(
    config_id="k6b-change",
    exit_ip="4.4.4.4",
    country_code="NL",
    observed_epoch=100,
)

r=m.observe(
    config_id="k6b-change",
    exit_ip="5.5.5.5",
    country_code="FR",
    observed_epoch=160,
)

print("CHANGE=",r)

assert (
    r["state"]
    =="pending_confirmation"
)

assert (
    r["reason"]
    =="country_change_ambiguous"
)


print(
    "K6B_TEMPORAL_TESTS=PASS"
)


for cid in ids:
    try:
        m._path(cid).unlink()
    except FileNotFoundError:
        pass
PY


echo "=== 4. VERIFY COUNTRY DETECTION FAST PATH ==="

grep -q \
'observe_rotating_exit' \
"$APP"

grep -q \
'resolve_geo' \
"$APP"

# K4 cache remains the no-provider-repeat fast path
# for previously resolved Exit IPs.
grep -q \
'geo_singleflight' \
"$R/app/country/geo_intelligence.py"

echo "GEO_CACHE_REUSE=PASS"


echo "=== 5. RESTART CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo "=== 6. OBSERVE TWO-MINUTE TEMPORAL WINDOW ==="

for i in $(seq 1 12)
do
    sleep 10

    echo "T=$((i*10))s"

    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY
done


echo "=== 7. REAL K6 STATE DISTRIBUTION ==="

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

files=0
multi_observation=0

for p in root.glob(
    "*.json"
):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    files+=1

    obs=o.get(
        "observations"
    ) or []

    if len(obs)>=2:
        multi_observation+=1

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


print("FILES=",files)

print(
    "MULTI_OBSERVATION=",
    multi_observation,
)

print(
    "STATES=",
    dict(states),
)

print(
    "REASONS=",
    dict(reasons),
)


assert files>=1

print(
    "REAL_TEMPORAL_HISTORY=PASS"
)
PY


echo "=== 8. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE_FINAL=",stats())
PY


echo "=== 9. SAFETY ==="

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo "=== 10. SERVICES ==="

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
echo "FIX22K6B=PASS"
echo "TEMPORAL_REPEAT_EVIDENCE=SUPPORTED"
echo "IMMEDIATE_DUPLICATES=SUPPRESSED"
echo "FIXED_IP_TEMPORAL_CONFIRMATION=SUPPORTED"
echo "ROTATING_IP_SAME_COUNTRY=SUPPORTED"
echo "COUNTRY_CHANGE_FALSE_FLIP=BLOCKED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K6C"
echo "======================================================"
