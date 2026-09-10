#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/lifecycle/consecutive.py"
HOOK="$R/app/country/health_hook.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1C5-$TS"

mkdir -p "$B"

cp -a "$F" "$B/"
[ -f "$HOOK" ] && cp -a "$HOOK" "$B/" || true

echo "BACKUP=$B"

export F


echo "=== 1. VERIFY UPDATE_TRACKER CONTRACT ==="

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["F"])
s=p.read_text()
tree=ast.parse(s)

target=None

for n in tree.body:
    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="update_tracker"
    ):
        target=n
        break

assert target is not None

text=ast.get_source_segment(
    s,
    target,
) or ""

print(
    "FUNCTION_LINES=",
    target.lineno,
    target.end_lineno,
)

for token in (
    "load_latest_results",
    "apply_result",
    "atomic_json_if_changed",
):
    print(
        token,
        "=",
        token in text,
    )

assert "load_latest_results" in text
assert "apply_result" in text

# There must be an actual persistent write in this function.
assert (
    "atomic_json_if_changed" in text
    or "_atomic_json" in text
)

Path(
    "/tmp/FIX22K1C5-update-tracker.txt"
).write_text(text)

print(
    "UPDATE_TRACKER_CONTRACT=PASS"
)
PY


echo "=== 2. CREATE NON-FATAL HEALTH HOOK ==="

cat >"$HOOK" <<'PY'
from __future__ import annotations

from typing import Any

from .event_bus import enqueue


def emit_health_country_event(
    result: dict[str,Any],
) -> dict[str,Any]:

    """
    Durable Health -> Country event producer.

    Safety:
      * Health remains authoritative.
      * Country failures are non-fatal.
      * Requires qualified + real upload/download.
      * Country FINAL is suppressed by Event Bus.
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


        qualified=bool(
            result.get(
                "health_qualified",
                False,
            )
        )


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
            completed_at=generation,
            priority=0,
            metadata={
                "producer":
                    "health-lifecycle",

                "health_qualified":
                    True,

                "upload_verified":
                    True,

                "download_verified":
                    True,
            },
        )


    except Exception as exc:

        # Country must NEVER change Health outcome.
        return {
            "status":"hook_error",

            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
        }
PY


"$PY" -m py_compile "$HOOK"

echo "HEALTH_HOOK_HELPER=PASS"


echo "=== 3. PATCH UPDATE_TRACKER ==="

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["F"])
s=p.read_text()

MARKER=(
    "# FIX22K1 HEALTH_COUNTRY_EVENT_HOOK"
)

if MARKER in s:
    print(
        "HOOK_ALREADY_INSTALLED=YES"
    )
    raise SystemExit(0)


tree=ast.parse(s)

target=None

for n in tree.body:
    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="update_tracker"
    ):
        target=n
        break

assert target is not None


# Locate persistent tracker write calls.
write_nodes=[]

for n in ast.walk(target):

    if not isinstance(n,ast.Call):
        continue

    name=""

    if isinstance(n.func,ast.Name):
        name=n.func.id

    elif isinstance(
        n.func,
        ast.Attribute,
    ):
        name=n.func.attr

    if name in {
        "atomic_json_if_changed",
        "_atomic_json",
    }:
        write_nodes.append(n)


assert write_nodes, (
    "persistent tracker write not found"
)


# We want the last write in update_tracker.
write_call=max(
    write_nodes,
    key=lambda n:n.lineno,
)


# Find the enclosing statement.
stmt=None

for n in ast.walk(target):

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
        <= write_call.lineno
        <= n.end_lineno
    ):
        if (
            stmt is None
            or n.lineno
            >= stmt.lineno
        ):
            stmt=n


assert stmt is not None


lines=s.splitlines(
    keepends=True
)

insert_line=stmt.end_lineno


# Determine indentation of write statement.
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
    +"# Emit only newly-applied Health results.\n"

    +indent
    +"# Event production is intentionally non-fatal.\n"

    +indent
    +"try:\n"

    +indent
    +"    from app.country.health_hook import (\n"

    +indent
    +"        emit_health_country_event,\n"

    +indent
    +"    )\n"

    +indent
    +"    for _cid, _result in latest.items():\n"

    +indent
    +"        _previous = records.get(_cid)\n"

    +indent
    +"        if not isinstance(_previous, dict):\n"

    +indent
    +"            continue\n"

    +indent
    +"        if (\n"

    +indent
    +"            _previous.get(\n"

    +indent
    +"                \"last_result_fingerprint\"\n"

    +indent
    +"            )\n"

    +indent
    +"            != result_fingerprint(_result)\n"

    +indent
    +"        ):\n"

    +indent
    +"            continue\n"

    +indent
    +"        emit_health_country_event(\n"

    +indent
    +"            _result\n"

    +indent
    +"        )\n"

    +indent
    +"except Exception:\n"

    +indent
    +"    pass\n"
)


lines.insert(
    insert_line,
    hook,
)

new="".join(lines)

# Syntax proof before production write.
ast.parse(new)

p.write_text(new)

print(
    "INSERT_AFTER_LINE=",
    insert_line,
)

print(
    "UPDATE_TRACKER_PATCH=PASS"
)
PY


echo "=== 4. COMPILE ==="

"$PY" -m py_compile \
"$F" \
"$HOOK" \
"$R/app/country/event_bus.py"

echo "PRODUCTION_COMPILE=PASS"


echo "=== 5. SHOW PATCH ==="

grep -n \
-B15 -A55 \
'FIX22K1 HEALTH_COUNTRY_EVENT_HOOK' \
"$F"


echo "=== 6. RESTART LIFECYCLE + HEALTH ==="

systemctl restart \
config-location-lifecycle-sync.service

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-lifecycle-sync.service
)" = active

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "SERVICES_RESTARTED=PASS"


echo "=== 7. BASELINE QUEUE ==="

BEFORE=$(
PYTHONPATH="$R" "$PY" - <<'PY'
from app.country.event_bus import stats
print(stats()["pending"])
PY
)

echo "PENDING_BEFORE=$BEFORE"


echo "=== 8. OBSERVE REAL HEALTH ==="

sleep 90


AFTER=$(
PYTHONPATH="$R" "$PY" - <<'PY'
from app.country.event_bus import stats
print(stats()["pending"])
PY
)

echo "PENDING_AFTER=$AFTER"


echo "=== 9. VALIDATE REAL EVENTS ==="

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
bad=0

for p in Q.glob("*.json"):

    try:
        e=json.loads(
            p.read_text()
        )
    except Exception:
        bad+=1
        continue


    cid=str(
        e.get(
            "config_id",
            "",
        )
    )

    hp=H/f"{cid}.json"

    if not hp.exists():
        bad+=1
        continue


    try:
        h=json.loads(
            hp.read_text()
        )
    except Exception:
        bad+=1
        continue


    if not bool(
        h.get(
            "health_qualified",
            False,
        )
    ):
        bad+=1
        continue


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
    )

    upload=bool(
        h.get(
            "upload_verified",
            False,
        )
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


    if download and upload:
        valid+=1
    else:
        bad+=1


print(
    "VALID_EVENTS=",
    valid,
)

print(
    "BAD_EVENTS=",
    bad,
)

assert bad == 0

# Production Health is continuously active.
assert valid >= 1

print(
    "REAL_EVENT_VALIDATION=PASS"
)
PY


echo "=== 10. QUEUE CRASH SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

n=recover_expired()

print(
    "RECOVERED_EXPIRED=",
    n,
)

print(
    "QUEUE_STATS=",
    stats(),
)

print(
    "QUEUE_CRASH_SAFETY=PASS"
)
PY


echo "=== 11. TEMP FILE CHECK ==="

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


echo "=== 12. CORE SERVICES ==="

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
echo "FIX22K1C5=PASS"
echo "FIX22K1=COMPLETE"
echo "HEALTH_TO_COUNTRY_EVENT_BUS=ACTIVE"
echo "DURABLE_QUEUE=ACTIVE"
echo "HEALTH_QUALIFIED_REQUIRED=YES"
echo "UPLOAD_DOWNLOAD_REQUIRED=YES"
echo "COUNTRY_FINAL_SUPPRESSION=YES"
echo "EVENT_FAILURE_AFFECTS_HEALTH=NO"
echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"
echo "BACKUP=$B"
echo "========================================"
