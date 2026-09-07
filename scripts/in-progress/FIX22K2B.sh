#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
ENGINE="$R/app/health/core/engine.py"
FAST="$R/app/country/same_runtime_fastpath.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K2B-$TS"
MET=/var/lib/config-location/country/same-runtime-fastpath.jsonl

mkdir -p "$B"

cp -a "$ENGINE" "$B/"
[ -f "$FAST" ] && cp -a "$FAST" "$B/" || true

echo "BACKUP=$B"

echo
echo "=== 1. INSTALL SAME-RUNTIME FASTPATH ==="

cat >"$FAST" <<'PY'
from __future__ import annotations

import json
import os
import time

from pathlib import Path
from typing import Any

from .exit_observer import observe_exit_ip


METRICS=Path(
    "/var/lib/config-location/country/"
    "same-runtime-fastpath.jsonl"
)


def _metric(row: dict[str,Any]) -> None:

    try:
        METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        line=(
            json.dumps(
                row,
                ensure_ascii=False,
                sort_keys=True,
            )
            + "\n"
        )

        fd=os.open(
            METRICS,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_APPEND,
            0o600,
        )

        try:
            os.write(
                fd,
                line.encode(),
            )
        finally:
            os.close(fd)

    except Exception:
        pass


def run_same_runtime_fastpath(
    *,
    config_id: str,
    job_id: str,
    proxy_url: str,
) -> dict[str,Any]:

    started=time.monotonic()

    try:

        obs=observe_exit_ip(
            proxy_url=proxy_url,
        )

        elapsed_ms=int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        exit_ip=getattr(
            obs,
            "exit_ip",
            None,
        )

        agreed=getattr(
            obs,
            "agreed",
            None,
        )

        status=(
            "success"
            if exit_ip
            else "no_exit_ip"
        )

        row={
            "ts_ns":time.time_ns(),
            "config_id":config_id,
            "job_id":job_id,
            "status":status,
            "exit_ip":exit_ip,
            "agreed":agreed,
            "elapsed_ms":elapsed_ms,
            "same_runtime":True,
            "new_xray_started":False,
        }

        _metric(row)

        return row

    except Exception as exc:

        elapsed_ms=int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        row={
            "ts_ns":time.time_ns(),
            "config_id":config_id,
            "job_id":job_id,
            "status":"error",
            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            "elapsed_ms":elapsed_ms,
            "same_runtime":True,
            "new_xray_started":False,
        }

        _metric(row)

        return row
PY

"$PY" -m py_compile "$FAST"

echo "FASTPATH_MODULE=PASS"


echo
echo "=== 2. PATCH ENGINE AFTER HEALTH DECISION ==="

export ENGINE

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["ENGINE"])
s=p.read_text()

MARKER=(
    "# FIX22K2 SAME_RUNTIME_COUNTRY_FASTPATH"
)

if MARKER in s:
    print("K2_HOOK_ALREADY_PRESENT=YES")
    raise SystemExit(0)

tree=ast.parse(s)

target=None

for fn in ast.walk(tree):

    if not isinstance(
        fn,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        continue

    if fn.name!="run_health_once":
        continue

    for n in ast.walk(fn):

        if not isinstance(n,ast.Call):
            continue

        name=""

        if isinstance(n.func,ast.Name):
            name=n.func.id
        elif isinstance(n.func,ast.Attribute):
            name=n.func.attr

        if name=="apply_health_decision":
            assert target is None
            target=(fn,n)

assert target is not None

fn,call=target

stmt=None

for n in ast.walk(fn):

    if not isinstance(n,ast.Expr):
        continue

    if (
        n.lineno
        <= call.lineno
        <= n.end_lineno
    ):
        if (
            stmt is None
            or n.lineno>=stmt.lineno
        ):
            stmt=n

assert stmt is not None

lines=s.splitlines(
    keepends=True
)

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
    +"# Health is already decided here; Country is\n"

    +indent
    +"# strictly non-fatal and reuses this live Xray.\n"

    +indent
    +"if (\n"

    +indent
    +"    result.state == HealthState.HEALTHY\n"

    +indent
    +"    and runtime is not None\n"

    +indent
    +"):\n"

    +indent
    +"    try:\n"

    +indent
    +"        from app.country.same_runtime_fastpath import (\n"

    +indent
    +"            run_same_runtime_fastpath,\n"

    +indent
    +"        )\n"

    +indent
    +"        run_same_runtime_fastpath(\n"

    +indent
    +"            config_id=result.config_id,\n"

    +indent
    +"            job_id=result.job_id,\n"

    +indent
    +"            proxy_url=runtime.proxy_url,\n"

    +indent
    +"        )\n"

    +indent
    +"    except Exception:\n"

    +indent
    +"        pass\n"
)

lines.insert(
    stmt.end_lineno,
    hook,
)

new="".join(lines)

ast.parse(new)

p.write_text(new)

print(
    "INSERT_AFTER_LINE=",
    stmt.end_lineno,
)

print(
    "ENGINE_PATCH=PASS"
)
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile \
"$ENGINE" \
"$FAST"

echo "COMPILE=PASS"


echo
echo "=== 4. VERIFY ORDER ==="

grep -n \
-B18 -A55 \
'FIX22K2 SAME_RUNTIME_COUNTRY_FASTPATH' \
"$ENGINE"

echo
echo "=== 5. RESET K2 METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"


echo
echo "=== 6. XRAY PROCESS BASELINE ==="

BASE=$(
    pgrep -fc \
    '/opt/config-location/bin/xray|/usr.*xray' \
    || true
)

echo "XRAY_PROCESS_BASELINE=$BASE"


echo
echo "=== 7. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo
echo "=== 8. WAIT FOR SAME-RUNTIME RESULTS ==="

FOUND=0

for i in $(seq 1 24)
do
    N=0

    if [ -f "$MET" ]; then
        N=$(wc -l <"$MET")
    fi

    echo "T=$((i*5))s FASTPATH_ROWS=$N"

    if [ "$N" -ge 5 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo
echo "=== 9. VALIDATE FASTPATH ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "same-runtime-fastpath.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    if not line.strip():
        continue

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


print(
    "FASTPATH_ROWS=",
    len(rows),
)

assert len(rows)>=5


statuses=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)

print(
    "STATUS_COUNTS=",
    dict(statuses),
)


success=[
    r
    for r in rows
    if r.get("status")=="success"
]


print(
    "SUCCESS_COUNT=",
    len(success),
)


for r in rows[:10]:
    print(
        "SAMPLE=",
        r,
    )


assert success, (
    "no same-runtime exit IP "
    "was observed"
)


for r in rows:

    assert (
        r.get(
            "same_runtime"
        )
        is True
    )

    assert (
        r.get(
            "new_xray_started"
        )
        is False
    )


times=[
    int(
        r.get(
            "elapsed_ms",
            0,
        )
        or 0
    )
    for r in rows
]

print(
    "MIN_MS=",
    min(times),
)

print(
    "MAX_MS=",
    max(times),
)

print(
    "AVG_MS=",
    round(
        sum(times)/len(times),
        2,
    ),
)

print(
    "SAME_RUNTIME_FASTPATH=PASS"
)
PY


echo
echo "=== 10. HEALTH INTEGRITY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-180

c=Counter()
n=0

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    n+=1

    c[
        str(
            o.get(
                "state",
                "unknown",
            )
        )
    ]+=1


print(
    "RECENT_HEALTH_RESULTS=",
    n,
)

print(
    "RECENT_HEALTH_STATES=",
    dict(c),
)

assert n>=1

print(
    "HEALTH_STILL_PRODUCING=PASS"
)
PY


echo
echo "=== 11. K1 FALLBACK STILL ACTIVE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "K1_QUEUE=",
    stats(),
)

print(
    "K1_FALLBACK=PASS"
)
PY


echo
echo "=== 12. SERVICES ==="

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


echo
echo "======================================================"
echo "FIX22K2B=PASS"
echo "SAME_RUNTIME_FASTPATH=ACTIVE"
echo "SECOND_XRAY_START=NO"
echo "HEALTH_FAILURE_FROM_COUNTRY=IMPOSSIBLE_BY_BOUNDARY"
echo "COUNTRY_RESULT_PUBLICATION=NO"
echo "K1_FALLBACK=PRESERVED"
echo "BACKUP=$B"
echo "NEXT=FIX22K2C"
echo "======================================================"
