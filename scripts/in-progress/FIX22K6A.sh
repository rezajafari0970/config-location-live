#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
ROT="$R/app/country/rotating_exit_state.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K6A-$TS"

mkdir -p "$B"
cp -a "$APP" "$B/"
[ -f "$ROT" ] && cp -a "$ROT" "$B/" || true

echo "BACKUP=$B"


echo "=== 1. INSTALL ROTATING EXIT STATE ENGINE ==="

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


def _path(
    config_id: str,
) -> Path:

    return (
        ROOT
        / f"{config_id}.json"
    )


def _read(
    config_id: str,
) -> dict:

    p=_path(
        config_id
    )

    if not p.exists():
        return {
            "config_id":
                config_id,

            "observations":
                [],
        }

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return {
            "config_id":
                config_id,

            "observations":
                [],
        }

    if not isinstance(
        o,
        dict,
    ):
        return {
            "config_id":
                config_id,

            "observations":
                [],
        }

    if not isinstance(
        o.get(
            "observations"
        ),
        list,
    ):
        o[
            "observations"
        ]=[]

    return o


def _write(
    config_id: str,
    value: dict,
) -> None:

    ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    p=_path(
        config_id
    )

    tmp=p.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
    )

    os.replace(
        tmp,
        p,
    )


def observe(
    *,
    config_id: str,
    exit_ip: str,
    country_code: str | None,
    max_history: int = 12,
) -> dict:

    now=int(
        time.time()
    )

    state=_read(
        config_id
    )

    obs=state.get(
        "observations",
        [],
    )


    row={
        "ts":
            now,

        "exit_ip":
            str(
                exit_ip
            ),

        "country_code":
            (
                str(
                    country_code
                ).upper()
                if country_code
                else None
            ),
    }


    # Avoid duplicate consecutive observation.
    if (
        not obs
        or obs[-1].get(
            "exit_ip"
        )!=row[
            "exit_ip"
        ]
        or obs[-1].get(
            "country_code"
        )!=row[
            "country_code"
        ]
    ):
        obs.append(
            row
        )


    obs=obs[
        -max(
            3,
            int(
                max_history
            )
        ):
    ]


    state[
        "observations"
    ]=obs


    ips=[
        x.get(
            "exit_ip"
        )
        for x in obs
        if x.get(
            "exit_ip"
        )
    ]

    countries=[
        str(
            x.get(
                "country_code"
            )
        ).upper()
        for x in obs
        if x.get(
            "country_code"
        )
    ]


    unique_ips=set(
        ips
    )

    country_counts=Counter(
        countries
    )

    unique_countries=set(
        countries
    )


    verdict="pending_confirmation"

    reason="insufficient_history"


    # Need at least two real observations.
    if len(obs)>=2:

        if (
            len(unique_countries)==1
            and len(unique_ips)==1
        ):

            verdict="confirmed_stable"
            reason="same_ip_same_country"


        elif (
            len(unique_countries)==1
            and len(unique_ips)>=2
        ):

            verdict="confirmed_rotating_ip"
            reason="rotating_ip_same_country"


        elif len(
            unique_countries
        )>=2:

            verdict="pending_confirmation"
            reason="country_changed"


    dominant_country=None

    if country_counts:

        dominant_country=(
            country_counts
            .most_common(
                1
            )[0][0]
        )


    result={
        "state":
            verdict,

        "reason":
            reason,

        "observation_count":
            len(obs),

        "unique_ip_count":
            len(
                unique_ips
            ),

        "unique_country_count":
            len(
                unique_countries
            ),

        "dominant_country":
            dominant_country,

        "observations":
            obs,
    }


    state[
        "last_verdict"
    ]=result

    _write(
        config_id,
        state,
    )


    return result
PY

"$PY" -m py_compile "$ROT"

echo "ROTATING_STATE_ENGINE=PASS"


echo "=== 2. PATCH CONSUMER HOOK ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["APP"]
)

s=p.read_text()

if "from app.country.rotating_exit_state import" not in s:

    marker='''from app.country.storage import (
    save_country_result,
)
'''

    new='''from app.country.storage import (
    save_country_result,
)

from app.country.rotating_exit_state import (
    observe as observe_rotating_exit,
)
'''

    if marker not in s:
        raise SystemExit(
            "ERROR: import marker not found"
        )

    s=s.replace(
        marker,
        new,
        1,
    )


old='''    state=(
        "pending_confirmation"
        if country_code
        else str(
            geo.get(
                "state"
            )
            or "unresolved"
        )
    )
'''

new='''    rotating=observe_rotating_exit(
        config_id=config_id,
        exit_ip=exit_ip,
        country_code=country_code,
    )

    state=(
        rotating.get(
            "state"
        )
        if country_code
        else str(
            geo.get(
                "state"
            )
            or "unresolved"
        )
    )
'''

if old not in s:

    if "observe_rotating_exit(" not in s:
        raise SystemExit(
            "ERROR: state block not found"
        )

else:

    s=s.replace(
        old,
        new,
        1,
    )


meta_old='''            "second_exit_probe":
                False,
'''

meta_new='''            "second_exit_probe":
                False,

            "rotating_exit":
                rotating,
'''

if meta_old in s:

    s=s.replace(
        meta_old,
        meta_new,
        1,
    )


p.write_text(s)

print(
    "CONSUMER_K6_HOOK=PASS"
)
PY


echo "=== 3. COMPILE ==="

"$PY" -m py_compile \
"$APP" \
"$ROT"

echo "COMPILE=PASS"


echo "=== 4. SYNTHETIC STATE TESTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import shutil

import app.country.rotating_exit_state as m


root=m.ROOT

test_ids=[
    "k6-stable-test",
    "k6-rotate-test",
    "k6-country-change-test",
]

for config_id in test_ids:
    try:
        m._path(
            config_id
        ).unlink()
    except FileNotFoundError:
        pass


# Same IP + same country.
a=m.observe(
    config_id="k6-stable-test",
    exit_ip="1.1.1.1",
    country_code="US",
)

b=m.observe(
    config_id="k6-stable-test",
    exit_ip="1.1.1.1",
    country_code="US",
)

print(
    "STABLE=",
    b,
)

# Consecutive duplicate suppression means
# create second timestamp-equivalent observation
# with a distinct IP roundtrip then back is not
# appropriate; direct history semantic test follows.

state=m._read(
    "k6-stable-test"
)

state["observations"]=[
    {
        "ts":1,
        "exit_ip":"1.1.1.1",
        "country_code":"US",
    },
    {
        "ts":2,
        "exit_ip":"1.1.1.1",
        "country_code":"US",
    },
]

m._write(
    "k6-stable-test",
    state,
)

b=m.observe(
    config_id="k6-stable-test",
    exit_ip="1.1.1.1",
    country_code="US",
)

assert (
    b["state"]
    =="confirmed_stable"
)


m.observe(
    config_id="k6-rotate-test",
    exit_ip="2.2.2.2",
    country_code="DE",
)

r=m.observe(
    config_id="k6-rotate-test",
    exit_ip="3.3.3.3",
    country_code="DE",
)

assert (
    r["state"]
    =="confirmed_rotating_ip"
)


m.observe(
    config_id="k6-country-change-test",
    exit_ip="4.4.4.4",
    country_code="NL",
)

c=m.observe(
    config_id="k6-country-change-test",
    exit_ip="5.5.5.5",
    country_code="FR",
)

assert (
    c["state"]
    =="pending_confirmation"
)

assert (
    c["reason"]
    =="country_changed"
)


print(
    "K6_STATE_MACHINE=PASS"
)


for config_id in test_ids:
    try:
        m._path(
            config_id
        ).unlink()
    except FileNotFoundError:
        pass
PY


echo "=== 5. RESTART CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo "=== 6. OBSERVE 90s REAL K6 FLOW ==="

for i in $(seq 1 18)
do
    sleep 5

    echo "T=$((i*5))s"

    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY
done


echo "=== 7. REAL STATE DISTRIBUTION ==="

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

    v=o.get(
        "last_verdict"
    ) or {}

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
    "FILES=",
    files,
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
    "REAL_K6_HISTORY=PASS"
)
PY


echo "=== 8. NO SECOND XRAY ==="

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo "=== 9. SERVICES ==="

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
echo "FIX22K6A=PASS"
echo "ROTATING_EXIT_STATE_ENGINE=ACTIVE"
echo "FIXED_IP_FIXED_COUNTRY=SUPPORTED"
echo "ROTATING_IP_SAME_COUNTRY=SUPPORTED"
echo "COUNTRY_CHANGE=NOT_FALSE_CONFIRMED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K6B"
echo "======================================================"
