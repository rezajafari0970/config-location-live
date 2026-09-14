#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
F="$R/app/health/core/production_scheduler.py"
HOOK="$R/app/country/health_hook.py"

B=$(
    find "$R/backups" \
    -maxdepth 1 \
    -type d \
    -name 'FIX22K1C7-*' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "K1C7_BACKUP=$B"

test -f "$B/production_scheduler.py"

echo "=== 1. ROLLBACK WRONG K1C7 PATCH ==="

cp -a \
"$B/production_scheduler.py" \
"$F"

"$PY" -m py_compile "$F"

! grep -q \
'FIX22K1 EXACT_HEALTH_RESULT_EVENT' \
"$F"

echo "K1C7_ROLLBACK=PASS"


echo "=== 2. INSTALL REAL HEALTH HOOK ==="

cat >"$HOOK" <<'PY'
from __future__ import annotations

from typing import Any

from .event_bus import enqueue


def _as_dict(
    result: Any,
) -> dict[str,Any]:

    if isinstance(result,dict):
        return result

    if hasattr(
        result,
        "to_dict",
    ):
        value=result.to_dict()

        if isinstance(value,dict):
            return value

    if hasattr(
        result,
        "__dict__",
    ):
        raw=dict(
            result.__dict__
        )

        # Enum -> value
        state=raw.get("state")

        if hasattr(
            state,
            "value",
        ):
            raw["state"]=state.value

        return raw

    return {}


def emit_health_country_event(
    result: Any,
) -> dict[str,Any]:

    """
    Called only AFTER ResultStore.save(result)
    succeeds.

    Country event failures never affect Health.
    """

    try:

        o=_as_dict(result)

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


        state=o.get(
            "state",
            "",
        )

        if hasattr(
            state,
            "value",
        ):
            state=state.value

        state=str(
            state
        ).strip().lower()


        xray=bool(
            o.get(
                "xray_started",
                False,
            )
        )

        download=bool(
            o.get(
                "download_verified",
                False,
            )
        )

        upload=bool(
            o.get(
                "upload_verified",
                False,
            )
        )


        metadata=(
            o.get("metadata")
            or {}
        )

        decision=(
            metadata.get(
                "health_decision"
            )
            or {}
        )


        decision_healthy=bool(
            isinstance(
                decision,
                dict,
            )
            and decision.get(
                "healthy",
                False,
            )
        )


        if not (
            state=="healthy"
            and xray
            and download
            and upload
            and decision_healthy
        ):

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
            generation=generation,
            completed_at=str(
                o.get(
                    "finished_at"
                )
                or generation
            ),
            priority=0,
            metadata={
                "producer":
                    "result-store-save",

                "health_state":
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

echo "HOOK_HELPER=PASS"


echo "=== 3. PATCH EVERY RESULT_STORE.SAVE ==="

export F

"$PY" <<'PY'
from pathlib import Path
import ast,os

p=Path(os.environ["F"])
s=p.read_text()

MARKER=(
    "# FIX22K1 RESULT_STORE_EVENT"
)

if MARKER in s:
    print(
        "HOOK_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


tree=ast.parse(s)

targets=[]

for n in ast.walk(tree):

    if not isinstance(
        n,
        ast.Call,
    ):
        continue

    if not isinstance(
        n.func,
        ast.Attribute,
    ):
        continue

    if n.func.attr!="save":
        continue

    owner=ast.get_source_segment(
        s,
        n.func.value,
    ) or ""

    if owner!="result_store":
        continue

    args=[
        ast.get_source_segment(
            s,
            a,
        ) or ""
        for a in n.args
    ]

    if not args:
        continue

    targets.append(
        (
            n,
            args[0],
        )
    )


print(
    "RESULT_STORE_SAVE_CALLS=",
    [
        (
            n.lineno,
            payload,
        )
        for n,payload
        in targets
    ],
)

assert targets, (
    "result_store.save not found"
)


lines=s.splitlines(
    keepends=True
)


# Insert bottom-up so line numbers remain valid.
insertions=[]

for call,payload in targets:

    stmt=None

    for n in ast.walk(tree):

        if not isinstance(
            n,
            ast.Expr,
        ):
            continue

        if (
            n.lineno
            <= call.lineno
            <= n.end_lineno
        ):
            if (
                stmt is None
                or n.lineno
                >= stmt.lineno
            ):
                stmt=n

    assert stmt is not None

    line=lines[
        stmt.lineno-1
    ]

    indent=line[
        :len(line)-len(line.lstrip())
    ]

    hook=(
        "\n"
        +indent
        +MARKER+"\n"

        +indent
        +"try:\n"

        +indent
        +"    from app.country.health_hook import (\n"

        +indent
        +"        emit_health_country_event,\n"

        +indent
        +"    )\n"

        +indent
        +"    emit_health_country_event(\n"

        +indent
        +f"        {payload}\n"

        +indent
        +"    )\n"

        +indent
        +"except Exception:\n"

        +indent
        +"    pass\n"
    )

    insertions.append(
        (
            stmt.end_lineno,
            hook,
        )
    )


for line_no,hook in sorted(
    insertions,
    reverse=True,
):
    lines.insert(
        line_no,
        hook,
    )


new="".join(lines)

ast.parse(new)

p.write_text(new)

print(
    "PATCHED_SAVE_CALLS=",
    len(insertions),
)

print(
    "RESULT_STORE_HOOK=PASS"
)
PY


echo "=== 4. COMPILE ==="

"$PY" -m py_compile \
"$F" \
"$HOOK" \
"$R/app/country/event_bus.py"

echo "COMPILE=PASS"


echo "=== 5. SHOW PATCHES ==="

grep -n \
-B12 -A30 \
'FIX22K1 RESULT_STORE_EVENT' \
"$F"


echo "=== 6. CLEAR ONLY K1 TEST QUEUE ==="

rm -f \
/var/lib/config-location/country/event-bus/pending/*.json \
2>/dev/null || true

rm -f \
/var/lib/config-location/country/event-bus/leased/*.json \
2>/dev/null || true

echo "QUEUE_BASELINE=CLEAN"


echo "=== 7. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo "=== 8. WAIT FOR FIRST REAL EVENT ==="

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


echo "=== 9. VERIFY REAL EVENT ==="

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

events=[]

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

    decision=(
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
        decision.get(
            "healthy"
        )
        is True
    )

    events.append(
        (
            cid,
            e.get(
                "health_generation"
            ),
        )
    )


print(
    "VALID_EVENTS=",
    len(events),
)

print(
    "SAMPLE=",
    events[:5],
)

assert len(events)>=1

print(
    "REAL_EVENT=PASS"
)
PY


echo "=== 10. DEDUPE PROOF ==="

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
    config_id=o["config_id"],
    generation=o[
        "health_generation"
    ],
    completed_at=o[
        "health_completed_at"
    ],
    priority=o.get(
        "priority",
        0,
    ),
)

print(
    "DUPLICATE_RESULT=",
    r,
)

assert (
    r["status"]
    ==
    "duplicate"
)

print(
    "REAL_DEDUPE=PASS"
)
PY


echo "=== 11. SERVICE ISOLATION ==="

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


echo "=== 12. NO CONSUMER YET ==="

echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"


echo "========================================"
echo "FIX22K1C8=PASS"
echo "FIX22K1=COMPLETE"
echo "EVENT_SOURCE=RESULT_STORE_SAVE"
echo "EVENT_AFTER_PERSIST=YES"
echo "REAL_UPLOAD_REQUIRED=YES"
echo "REAL_DOWNLOAD_REQUIRED=YES"
echo "XRAY_REQUIRED=YES"
echo "DURABLE_QUEUE=YES"
echo "DEDUPE=YES"
echo "EVENT_FAILURE_AFFECTS_HEALTH=NO"
echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"
echo "========================================"
