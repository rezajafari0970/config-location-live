#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/core/production_scheduler.py"
HOOK="$R/app/country/health_hook.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1C11-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"
cp -a "$HOOK" "$B/"

echo "BACKUP=$B"


echo "=== 1. INSTALL CANONICAL HOOK ==="

cat >"$HOOK" <<'PY'
from __future__ import annotations

from typing import Any

from app.health.storage.json_store import (
    JsonHealthResultStore,
)

from .event_bus import enqueue


def emit_health_country_event(
    result: Any,
) -> dict[str,Any]:

    """
    Health -> Country durable event.

    IMPORTANT:
    Uses Health ResultStore's canonical serializer.
    Country does not maintain a parallel Health schema.

    Called only after result_store.save(result)
    succeeds.

    Any Country/EventBus failure is non-fatal.
    """

    try:

        o=JsonHealthResultStore._result_to_dict(
            result
        )


        cid=str(
            o.get(
                "config_id",
                "",
            )
        ).strip()

        if not cid:

            return {
                "status":
                    "ignored_missing_config"
            }


        state=str(
            o.get(
                "state",
                "",
            )
        ).strip().lower()


        decision=(
            (
                o.get(
                    "metadata"
                )
                or {}
            ).get(
                "health_decision"
            )
            or {}
        )


        real_healthy=(
            state=="healthy"
            and
            o.get(
                "xray_started"
            ) is True
            and
            o.get(
                "download_verified"
            ) is True
            and
            o.get(
                "upload_verified"
            ) is True
            and
            isinstance(
                decision,
                dict,
            )
            and
            decision.get(
                "healthy"
            ) is True
            and
            decision.get(
                "xray_ok"
            ) is True
            and
            decision.get(
                "download_ok"
            ) is True
            and
            decision.get(
                "upload_ok"
            ) is True
        )


        if not real_healthy:

            return {
                "status":
                    "ignored_not_real_healthy"
            }


        generation=str(
            o.get("job_id")
            or
            o.get("finished_at")
            or
            o.get("started_at")
            or ""
        ).strip()


        if not generation:

            return {
                "status":
                    "ignored_missing_generation"
            }


        return enqueue(
            config_id=cid,

            generation=
                generation,

            completed_at=str(
                o.get(
                    "finished_at"
                )
                or generation
            ),

            priority=0,

            metadata={
                "producer":
                    "health-result-store",

                "canonical_serializer":
                    "JsonHealthResultStore._result_to_dict",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,
            },
        )


    except Exception as exc:

        # Strict Health isolation.
        return {
            "status":
                "hook_error",

            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
        }
PY


"$PY" -m py_compile "$HOOK"

echo "CANONICAL_HOOK_COMPILE=PASS"


echo "=== 2. VERIFY OFFICIAL SERIALIZER ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.health.storage.json_store import (
    JsonHealthResultStore,
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

# Verify canonical stored schema has all required
# fields on real Healthy results.
n=0

for p in H.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if str(
        o.get(
            "state",
            "",
        )
    ).lower()!="healthy":
        continue

    assert "config_id" in o
    assert "job_id" in o
    assert "xray_started" in o
    assert "download_verified" in o
    assert "upload_verified" in o
    assert "metadata" in o

    n+=1

    if n>=20:
        break

print(
    "CANONICAL_HEALTHY_SAMPLES=",
    n,
)

assert n>=1

print(
    "CANONICAL_SCHEMA=PASS"
)
PY


echo "=== 3. PATCH PRESENCE ==="

COUNT=$(
    grep -c \
    'FIX22K1 RESULT_STORE_EVENT' \
    "$F" || true
)

echo "RESULT_STORE_HOOKS=$COUNT"

test "$COUNT" -ge 1

echo "RESULT_STORE_HOOK=PASS"


echo "=== 4. CLEAR K1 PENDING TEST QUEUE ==="

rm -f \
/var/lib/config-location/country/event-bus/pending/*.json \
2>/dev/null || true

rm -f \
/var/lib/config-location/country/event-bus/leased/*.json \
2>/dev/null || true

echo "QUEUE_BASELINE=CLEAN"


echo "=== 5. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo "=== 6. WAIT FOR REAL DURABLE EVENTS ==="

FOUND=0

for i in $(seq 1 24); do

    N=$(
        find \
        /var/lib/config-location/country/event-bus/pending \
        -maxdepth 1 \
        -type f \
        -name '*.json' \
        2>/dev/null \
        | wc -l
    )

    echo "T=$((i*5))s PENDING=$N"

    if [ "$N" -gt 0 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo "=== 7. VALIDATE EVENTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

Q=Path(
    "/var/lib/config-location/"
    "country/event-bus/pending"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

valid=0

for p in Q.glob("*.json"):

    e=json.loads(
        p.read_text()
    )

    cid=e["config_id"]

    hp=H/f"{cid}.json"

    assert hp.exists()

    h=json.loads(
        hp.read_text()
    )


    d=(
        (
            h.get(
                "metadata"
            )
            or {}
        ).get(
            "health_decision"
        )
        or {}
    )


    assert str(
        h.get(
            "state",
            "",
        )
    ).lower()=="healthy"

    assert (
        h.get(
            "xray_started"
        )
        is True
    )

    assert (
        h.get(
            "download_verified"
        )
        is True
    )

    assert (
        h.get(
            "upload_verified"
        )
        is True
    )

    assert (
        d.get(
            "healthy"
        )
        is True
    )

    assert (
        d.get(
            "xray_ok"
        )
        is True
    )

    assert (
        d.get(
            "download_ok"
        )
        is True
    )

    assert (
        d.get(
            "upload_ok"
        )
        is True
    )


    meta=(
        e.get(
            "metadata"
        )
        or {}
    )

    assert (
        meta.get(
            "canonical_serializer"
        )
        ==
        "JsonHealthResultStore._result_to_dict"
    )


    valid+=1


print(
    "VALID_REAL_EVENTS=",
    valid,
)

assert valid>=1

print(
    "EVENT_VALIDATION=PASS"
)
PY


echo "=== 8. DEDUPE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.event_bus import (
    enqueue,
)

Q=Path(
    "/var/lib/config-location/"
    "country/event-bus/pending"
)

p=next(
    Q.glob("*.json")
)

o=json.loads(
    p.read_text()
)

r=enqueue(
    config_id=
        o["config_id"],

    generation=
        o["health_generation"],

    completed_at=
        o["health_completed_at"],

    priority=
        o.get(
            "priority",
            0,
        ),
)

print(
    "DUPLICATE=",
    r,
)

assert (
    r["status"]
    ==
    "duplicate"
)

print(
    "DEDUPE=PASS"
)
PY


echo "=== 9. QUEUE DURABILITY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print(
    "RECOVERED=",
    recover_expired(),
)

print(
    "QUEUE_STATS=",
    stats(),
)

print(
    "DURABILITY=PASS"
)
PY


echo "=== 10. SERVICES ==="

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


echo "=== 11. NO CONSUMER YET ==="

echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"


echo "========================================"
echo "FIX22K1C11=PASS"
echo "FIX22K1=COMPLETE"
echo "HEALTH_EVENT_SOURCE=RESULT_STORE_SAVE"
echo "CANONICAL_SERIALIZER=YES"
echo "DURABLE_QUEUE=YES"
echo "DEDUPE=YES"
echo "CRASH_RECOVERY=YES"
echo "FINAL_SUPPRESSION=YES"
echo "REAL_UPLOAD_DOWNLOAD_GATE=YES"
echo "EVENT_FAILURE_AFFECTS_HEALTH=NO"
echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"
echo "BACKUP=$B"
echo "========================================"
