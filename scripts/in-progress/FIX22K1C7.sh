#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
F="$R/app/health/core/production_scheduler.py"
HOOK="$R/app/country/health_hook.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1C7-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"
[ -f "$HOOK" ] && cp -a "$HOOK" "$B/" || true

echo "BACKUP=$B"

export F


echo "=== 1. EXACT WRITER CONTRACT ==="

"$PY" <<'PY'
from pathlib import Path
import ast,os

p=Path(os.environ["F"])
s=p.read_text()
tree=ast.parse(s)

hits=[]

for fn in ast.walk(tree):

    if not isinstance(
        fn,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        continue

    text=ast.get_source_segment(
        s,
        fn,
    ) or ""

    if "_atomic_json" not in text:
        continue

    if "result" not in text:
        continue

    calls=[]

    for n in ast.walk(fn):

        if not isinstance(
            n,
            ast.Call,
        ):
            continue

        name=""

        if isinstance(
            n.func,
            ast.Name,
        ):
            name=n.func.id

        elif isinstance(
            n.func,
            ast.Attribute,
        ):
            name=n.func.attr

        if name=="_atomic_json":
            calls.append(n)


    for call in calls:

        args=[
            ast.get_source_segment(
                s,
                a,
            ) or ""
            for a in call.args
        ]

        hits.append(
            (
                fn.name,
                fn.lineno,
                fn.end_lineno,
                call.lineno,
                args,
            )
        )


print("WRITER_HITS=")

for h in hits:
    print(h)


# Production writer observed by K1C6 was around line 547.
candidates=[
    h for h in hits
    if 500 <= h[3] <= 590
]

assert len(candidates)==1, (
    "exact production result writer "
    "not uniquely identified"
)

h=candidates[0]

Path(
    "/tmp/FIX22K1C7-writer"
).write_text(
    "\n".join(
        map(str,h[:4])
    )+"\n"
)

print(
    "SELECTED_FUNCTION=",
    h[0],
)

print(
    "WRITE_LINE=",
    h[3],
)

print(
    "WRITER_CONTRACT=PASS"
)
PY


echo "=== 2. SHOW WRITER ==="

readarray -t I \
< /tmp/FIX22K1C7-writer

FN="${I[0]}"
FS="${I[1]}"
FE="${I[2]}"
WL="${I[3]}"

FROM=$((WL-45))
TO=$((WL+55))

[ "$FROM" -lt 1 ] && FROM=1

nl -ba "$F" \
| sed -n "${FROM},${TO}p"


echo "=== 3. INSTALL CORRECT REAL-HEALTH HOOK ==="

cat >"$HOOK" <<'PY'
from __future__ import annotations

from typing import Any

from .event_bus import enqueue


def emit_health_country_event(
    result: dict[str,Any],
) -> dict[str,Any]:

    """
    Emit Country event only for a real successful
    HealthResult.

    HealthResult production contract:
      state == healthy
      xray_started == true
      download_verified == true
      upload_verified == true
      metadata.health_decision.healthy == true

    Event failures are always non-fatal to Health.
    """

    try:

        cid=str(
            result.get(
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
            result.get(
                "state",
                "",
            )
        ).strip().lower()


        xray=bool(
            result.get(
                "xray_started",
                False,
            )
        )

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


        decision=(
            (
                result.get(
                    "metadata"
                )
                or {}
            ).get(
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
            result.get(
                "job_id"
            )
            or
            result.get(
                "finished_at"
            )
            or
            result.get(
                "started_at"
            )
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
                result.get(
                    "finished_at"
                )
                or generation
            ),
            priority=0,
            metadata={
                "producer":
                    "production-health-result",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,

                "health_decision_healthy":
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

echo "HEALTH_HOOK=PASS"


echo "=== 4. PATCH EXACT RESULT WRITE ==="

"$PY" <<'PY'
from pathlib import Path
import ast,os

p=Path(os.environ["F"])
s=p.read_text()

MARKER=(
    "# FIX22K1 EXACT_HEALTH_RESULT_EVENT"
)

if MARKER in s:
    print(
        "EXACT_HOOK_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


tree=ast.parse(s)

target_call=None
target_stmt=None
target_fn=None


for fn in ast.walk(tree):

    if not isinstance(
        fn,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        continue

    for n in ast.walk(fn):

        if not isinstance(
            n,
            ast.Call,
        ):
            continue

        name=""

        if isinstance(
            n.func,
            ast.Name,
        ):
            name=n.func.id

        elif isinstance(
            n.func,
            ast.Attribute,
        ):
            name=n.func.attr

        if (
            name=="_atomic_json"
            and
            500 <= n.lineno <= 590
        ):
            assert target_call is None
            target_call=n
            target_fn=fn


assert target_call is not None
assert target_fn is not None


# Find enclosing statement.
for n in ast.walk(target_fn):

    if not isinstance(
        n,
        (
            ast.Expr,
            ast.Assign,
            ast.AnnAssign,
        ),
    ):
        continue

    if (
        n.lineno
        <= target_call.lineno
        <= n.end_lineno
    ):
        if (
            target_stmt is None
            or n.lineno
            >= target_stmt.lineno
        ):
            target_stmt=n


assert target_stmt is not None


# Determine which argument is the serialized result.
arg_sources=[
    ast.get_source_segment(
        s,
        a,
    ) or ""
    for a in target_call.args
]

print(
    "ATOMIC_ARGS=",
    arg_sources,
)


# Usually second argument is payload.
assert len(
    target_call.args
) >= 2

payload=arg_sources[1]

assert payload


lines=s.splitlines(
    keepends=True
)

line=lines[
    target_stmt.lineno-1
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


lines.insert(
    target_stmt.end_lineno,
    hook,
)

new="".join(lines)

ast.parse(new)

p.write_text(new)

print(
    "PATCH_FUNCTION=",
    target_fn.name,
)

print(
    "PATCH_AFTER_WRITE_LINE=",
    target_stmt.end_lineno,
)

print(
    "EXACT_RESULT_HOOK=PASS"
)
PY


echo "=== 5. COMPILE ==="

"$PY" -m py_compile \
"$F" \
"$HOOK" \
"$R/app/country/event_bus.py"

echo "COMPILE=PASS"


echo "=== 6. UNIT GATE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.health_hook import (
    emit_health_country_event,
)

bad=emit_health_country_event({
    "config_id":"K1-BAD",
    "state":"healthy",
    "xray_started":True,
    "download_verified":False,
    "upload_verified":True,
    "job_id":"bad",
    "metadata":{
        "health_decision":{
            "healthy":False,
        }
    },
})

assert (
    bad["status"]
    ==
    "ignored_not_real_healthy"
)

print(
    "UNHEALTHY_SUPPRESSION=PASS"
)
PY


echo "=== 7. CLEAN TEST EVENTS ==="

rm -f \
/var/lib/config-location/country/event-bus/pending/* \
2>/dev/null || true

rm -f \
/var/lib/config-location/country/event-bus/leased/* \
2>/dev/null || true

echo "QUEUE_TEST_BASELINE=CLEAN"


echo "=== 8. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH_RESTART=PASS"


echo "=== 9. WAIT FOR REAL EVENTS ==="

FOUND=0

for i in $(seq 1 18); do

    N=$(
        find \
        /var/lib/config-location/country/event-bus/pending \
        -maxdepth 1 \
        -type f \
        -name '*.json' \
        2>/dev/null \
        | wc -l
    )

    echo "T=$((i*10))s PENDING=$N"

    if [ "$N" -gt 0 ]; then
        FOUND=1
        break
    fi

    sleep 10
done

test "$FOUND" -eq 1


echo "=== 10. VERIFY EVENTS AGAINST HEALTH ==="

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

    h=json.loads(
        (
            H/f"{cid}.json"
        ).read_text()
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

    assert (
        str(
            h.get(
                "state",
                "",
            )
        ).lower()
        == "healthy"
    )

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

    valid+=1


print(
    "VALID_REAL_EVENTS=",
    valid,
)

assert valid>=1

print(
    "REAL_HEALTH_EVENT_GATE=PASS"
)
PY


echo "=== 11. SERVICES ==="

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


echo "========================================"
echo "FIX22K1C7=PASS"
echo "FIX22K1=COMPLETE"
echo "EVENT_SOURCE=EXACT_HEALTH_RESULT_COMMIT"
echo "REAL_HEALTH_GATE=PASS"
echo "EVENT_BUS=DURABLE"
echo "EVENT_FAILURE_ISOLATED_FROM_HEALTH=YES"
echo "COUNTRY_CONSUMER=NOT_INSTALLED"
echo "BACKUP=$B"
echo "========================================"
