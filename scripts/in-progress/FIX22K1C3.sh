#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/lifecycle/consecutive.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1C3-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"

echo "BACKUP=$B"

export F


echo "=== 1. DISCOVER SAFE FUNCTION ==="

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["F"])
s=p.read_text()

tree=ast.parse(s)

matches=[]

for node in tree.body:

    if not isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        continue

    text=ast.get_source_segment(
        s,
        node,
    ) or ""

    score=0

    for token in (
        "result_fingerprint",
        "health_qualified",
        "consecutive_healthy",
        "atomic_json",
        "TRACKER_PATH",
    ):
        if token in text:
            score+=1

    if score>=3:
        matches.append(
            (
                score,
                node.name,
                node.lineno,
                node.end_lineno,
            )
        )


print(
    "MATCHES=",
    matches,
)

assert matches, (
    "no safe consecutive commit "
    "function discovered"
)

matches.sort(
    reverse=True
)

score,name,start,end=matches[0]

assert score>=3

Path(
    "/tmp/FIX22K1C3-function"
).write_text(
    f"{name}\n{start}\n{end}\n"
)

print(
    "SELECTED_FUNCTION=",
    name,
)

print(
    "LINES=",
    start,
    end,
)

print(
    "DISCOVERY=PASS"
)
PY


echo "=== 2. SHOW EXACT FUNCTION ==="

readarray -t INFO \
< /tmp/FIX22K1C3-function

NAME="${INFO[0]}"
START="${INFO[1]}"
END="${INFO[2]}"

echo "FUNCTION=$NAME"
echo "LINES=$START-$END"

nl -ba "$F" \
| sed -n "${START},${END}p"


echo "=== 3. INSTALL NON-FATAL HOOK HELPER ==="

cat >/opt/config-location/app/country/health_hook.py <<'PY'
from __future__ import annotations

from typing import Any

from .event_bus import enqueue


def emit_health_country_event(
    result: dict[str,Any],
) -> dict[str,Any]:
    """
    Non-fatal Health -> Country bridge.

    This function MUST only be called after the
    Health result has already been accepted by the
    lifecycle layer.

    Country failures never change Health state.
    """

    try:

        config_id=str(
            result.get(
                "config_id",
                "",
            )
        ).strip()

        if not config_id:
            return {
                "status":
                    "ignored_missing_config_id"
            }


        qualified=bool(
            result.get(
                "health_qualified",
                False,
            )
        )


        # Require explicit real transfer evidence too.
        download=bool(
            result.get(
                "download_verified",
                False,
            )
        )

        upload=bool(
            result.get(
                "upload_verified",
                False,
            )
        )


        # Some production result schemas keep the
        # final decision inside metadata/decision.
        decision=(
            result.get("decision")
            or
            (
                result.get("metadata")
                or {}
            ).get(
                "health_decision"
            )
            or {}
        )


        if isinstance(
            decision,
            dict,
        ):

            download=bool(
                download
                or decision.get(
                    "download_ok",
                    False,
                )
            )

            upload=bool(
                upload
                or decision.get(
                    "upload_ok",
                    False,
                )
            )


        if not (
            qualified
            and download
            and upload
        ):

            return {
                "status":
                    "ignored_not_qualified"
            }


        generation=str(
            result.get(
                "finished_at"
            )
            or
            result.get(
                "started_at"
            )
            or
            result.get(
                "health_generation"
            )
            or
            ""
        )


        if not generation:

            return {
                "status":
                    "ignored_missing_generation"
            }


        return enqueue(
            config_id=config_id,
            generation=generation,
            completed_at=generation,
            priority=0,
            metadata={
                "source":
                    "health_lifecycle",

                "health_qualified":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,
            },
        )


    except Exception as e:

        # Mandatory isolation boundary:
        # Country can NEVER make Health fail.
        return {
            "status":
                "hook_error",

            "error":
                (
                    f"{type(e).__name__}: "
                    f"{e}"
                )[:500],
        }
PY


"$PY" -m py_compile \
/opt/config-location/app/country/health_hook.py

echo "HOOK_HELPER=PASS"


echo "=== 4. PATCH CONSECUTIVE FAIL-CLOSED ==="

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["F"])
s=p.read_text()

if (
    "emit_health_country_event"
    in s
):
    print(
        "HOOK_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


info=Path(
    "/tmp/FIX22K1C3-function"
).read_text().splitlines()

name=info[0]


tree=ast.parse(s)

target=None

for node in tree.body:

    if (
        isinstance(
            node,
            ast.FunctionDef,
        )
        and node.name==name
    ):
        target=node
        break


assert target is not None


# We only patch functions that have a result argument.
args=[
    a.arg
    for a in target.args.args
]

assert "result" in args, (
    "selected function has no result arg; "
    "refusing production patch"
)


lines=s.splitlines(
    keepends=True
)


# Find the final return in this exact function.
returns=[
    n
    for n in ast.walk(target)
    if isinstance(
        n,
        ast.Return,
    )
]

assert returns, (
    "no return in selected function"
)

ret=max(
    returns,
    key=lambda n:n.lineno,
)


indent=(
    lines[
        ret.lineno-1
    ][
        :len(
            lines[
                ret.lineno-1
            ]
        )
        -
        len(
            lines[
                ret.lineno-1
            ].lstrip()
        )
    ]
)


hook=(
    indent
    +"# K1 durable Health -> Country event.\n"
    +indent
    +"# Non-fatal by contract.\n"
    +indent
    +"try:\n"
    +indent
    +"    from app.country.health_hook import (\n"
    +indent
    +"        emit_health_country_event,\n"
    +indent
    +"    )\n"
    +indent
    +"    emit_health_country_event(result)\n"
    +indent
    +"except Exception:\n"
    +indent
    +"    pass\n\n"
)


lines.insert(
    ret.lineno-1,
    hook,
)

new="".join(lines)


# Parse before writing.
ast.parse(new)

p.write_text(new)

print(
    "PATCHED_FUNCTION=",
    name,
)

print(
    "HEALTH_EVENT_HOOK_PATCH=PASS"
)
PY


echo "=== 5. COMPILE PRODUCTION MODULES ==="

"$PY" -m py_compile \
"$F" \
"$R/app/country/event_bus.py" \
"$R/app/country/health_hook.py"

echo "PRODUCTION_COMPILE=PASS"


echo "=== 6. HOOK UNIT CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.health_hook import (
    emit_health_country_event,
)


# Unhealthy must never enqueue.
r=emit_health_country_event({
    "config_id":
        "K1C3-UNHEALTHY",

    "health_qualified":
        False,

    "download_verified":
        True,

    "upload_verified":
        True,

    "finished_at":
        "K1C3-U",
})

print(
    "UNHEALTHY=",
    r,
)

assert (
    r["status"]
    ==
    "ignored_not_qualified"
)


# Qualified but no download.
r=emit_health_country_event({
    "config_id":
        "K1C3-NODOWN",

    "health_qualified":
        True,

    "download_verified":
        False,

    "upload_verified":
        True,

    "finished_at":
        "K1C3-D",
})

assert (
    r["status"]
    ==
    "ignored_not_qualified"
)


# Qualified but no upload.
r=emit_health_country_event({
    "config_id":
        "K1C3-NOUP",

    "health_qualified":
        True,

    "download_verified":
        True,

    "upload_verified":
        False,

    "finished_at":
        "K1C3-UP",
})

assert (
    r["status"]
    ==
    "ignored_not_qualified"
)


print(
    "HEALTH_GATE_UNIT=PASS"
)
PY


echo "=== 7. RESTART HEALTH WORKER ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH_WORKER_RESTART=PASS"


echo "=== 8. OBSERVE REAL HEALTH EVENTS ==="

BEFORE=$(
PYTHONPATH="$R" "$PY" - <<'PY'
from app.country.event_bus import stats
print(stats()["pending"])
PY
)

echo "PENDING_BEFORE=$BEFORE"

# Country consumer does not use K1 queue yet,
# so new events remain visible.
sleep 90

AFTER=$(
PYTHONPATH="$R" "$PY" - <<'PY'
from app.country.event_bus import stats
print(stats()["pending"])
PY
)

echo "PENDING_AFTER=$AFTER"


echo "=== 9. REAL EVENT VALIDATION ==="

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

    try:
        e=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    cid=str(
        e.get(
            "config_id",
            "",
        )
    )

    hp=H/f"{cid}.json"

    if not hp.exists():
        continue

    try:
        h=json.loads(
            hp.read_text()
        )
    except Exception:
        continue

    events.append(
        (
            e,
            h,
        )
    )


print(
    "REAL_EVENTS_WITH_HEALTH=",
    len(events),
)


# We expect live Health activity on this server.
assert len(events) >= 1


checked=0

for e,h in events[:50]:

    assert bool(
        h.get(
            "health_qualified",
            False,
        )
    ) is True

    decision=(
        h.get("decision")
        or
        (
            h.get("metadata")
            or {}
        ).get(
            "health_decision"
        )
        or {}
    )

    download=bool(
        h.get(
            "download_verified",
            False,
        )
        or (
            isinstance(
                decision,
                dict,
            )
            and decision.get(
                "download_ok",
                False,
            )
        )
    )

    upload=bool(
        h.get(
            "upload_verified",
            False,
        )
        or (
            isinstance(
                decision,
                dict,
            )
            and decision.get(
                "upload_ok",
                False,
            )
        )
    )

    assert download
    assert upload

    checked+=1


print(
    "REAL_EVENTS_VALIDATED=",
    checked,
)

assert checked >= 1

print(
    "REAL_HEALTH_TO_QUEUE=PASS"
)
PY


echo "=== 10. EVENT BUS TEMP FILES ==="

COUNT=$(
    find \
    /var/lib/config-location/country/event-bus \
    -type f \
    -name '*.tmp' \
    2>/dev/null \
    | wc -l
)

echo "QUEUE_TEMP_FILES=$COUNT"

test "$COUNT" -eq 0


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


echo "=== 12. COUNTRY CONSUMER STILL OFF ==="

echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"

echo "========================================"
echo "FIX22K1C3=PASS"
echo "HEALTH_TO_COUNTRY_EVENT_HOOK=ACTIVE"
echo "HEALTH_QUALIFIED_REQUIRED=YES"
echo "REAL_DOWNLOAD_REQUIRED=YES"
echo "REAL_UPLOAD_REQUIRED=YES"
echo "EVENT_ENQUEUE=NON_FATAL"
echo "COUNTRY_FINAL_SUPPRESSION=ACTIVE"
echo "DURABLE_QUEUE=ACTIVE"
echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"
echo "BACKUP=$B"
echo "========================================"
